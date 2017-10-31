module Network.Apns.Internal where

import Control.Applicative ((<|>))
import Control.Concurrent.Async (async, cancel, waitCatchSTM)
import Control.Concurrent.Lifted (fork)
import Control.Concurrent.STM (STM, atomically, retry)
import Control.Concurrent.STM.TBMQueue (TBMQueue, closeTBMQueue, isClosedTBMQueue, newTBMQueueIO, readTBMQueue, writeTBMQueue)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, writeTVar)
import Control.Exception (IOException, SomeException)
import Control.Exception.Lifted (bracketOnError, handle, throwIO, try)
import Control.Monad ((<=<), guard, join, unless, when)
import Control.Monad.Error.Class (throwError)
import Control.Monad.Except (ExceptT(ExceptT), runExceptT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Morph (hoist)
import Control.Monad.Reader (ReaderT, runReaderT)
import Control.Monad.Reader.Class (MonadReader)
import Control.Monad.State.Strict (StateT, runStateT)
import Control.Monad.Trans (lift)
import Control.Lens
  ( _Cons, _Just, _Snoc, (<&>), assign, at, both, each, filtered, folded, ifolded, modifying, over, preview, set, sumOf, to, toListOf, use, uses, withIndex, view )
import Control.Lens.TH (makeLenses, makePrisms)
import Data.Aeson ((.:), (.:?), Value, eitherDecode', withObject)
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.Bool (bool)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (byteStringHex, toLazyByteString)
import qualified Data.ByteString.Char8 as BSC8
import qualified Data.ByteString.Lazy as BL
import Data.Conduit (ConduitM, Producer, (.|), ($$), awaitForever, yield)
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.List as CL
import Data.Conduit.TQueue (sinkTBMQueue, sourceTBMQueue)
import Data.Default (def)
import Data.Foldable (for_, traverse_)
import Data.Functor (($>), void)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Key (traverseWithKey_)
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Monoid ((<>))
import Data.Text (Text, pack)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (NominalDiffTime, UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.Word (Word32)
import Data.X509.Validation (validateDefault)
import Network.Apns.Types
  ( ApnsConnection(ApnsConnection)
  , ApnsConnectionError(..)
  , ApnsConnectionParams(..), apnsConnectionParams_hostName, apnsConnectionParams_portNumber, apnsConnectionParams_onDebugLog
  , apnsConnectionParams_pushQueueSize, apnsConnectionParams_readQueueSize, apnsConnectionParams_writeQueueSize, apnsConnectionParams_onTermination
  , ApnsError(ApnsError)
  , ApnsErrorReason, apnsErrorReasonFromText
  , ApnsPush, _apnsPush_callback, apnsPush_data
  , ApnsPushData(ApnsPushData), _apnsPushData_collapseId, _apnsPushData_deviceToken, _apnsPushData_expiration, apnsPushData_payload, _apnsPushData_priority
  , _apnsPushData_topic
  , ApnsPushResult(..)
  , ApnsTerminationReason(..)
  )
import Network.BSD (getProtocolNumber)
import qualified Network.HPACK as HP
import qualified Network.HTTP2 as H2
import Network.Socket (Socket)
import qualified Network.Socket as Socket
import qualified Network.TLS as TLS
import Network.TLS.Extra.Cipher (ciphersuite_strong)
import Text.Read (readMaybe)


-- |Event emitted by the reader thread.
data ReaderEvent
  = ReadFrame H2.Frame
  -- ^Reader read a well formed and not obviously wrong HTTP2 frame which is not a SETTINGS frame.
  | ReadSettingsUpdate H2.Settings
  -- ^Reader encountered a SETTINGS frame and updated its internal settings. The SETTINGS frame still needs to be adopted by the processor and acknowledged.
  | ReadH2Error H2.ErrorCodeId ByteString ApnsTerminationReason
  -- ^Reader failed to process incoming data due to some catastrophic protocol error.
  deriving Show

-- |Environmental context for the processing system, passed around as a 'ReaderT'.
data Context = Context
  { _context_params        :: ApnsConnectionParams
  -- ^The 'ApnsConnectionParams' used to open the connection.
  , _context_authority     :: ByteString
  -- ^The cached HTTP authority value sent with each request.
  , _context_closingTv     :: TVar (Maybe ApnsTerminationReason)
  -- ^'TVar' that is @Just@ when the connection is being closed due to local or remote action but not all streams have been processed yet.
  , _context_pushQueue     :: TBMQueue ApnsPush
  -- ^The 'TBMQueue' that '_apnsConnection_submitPush' enqueues using. If this queue is closed, then the connection is closed and can't deliver any more
  -- push notifications.
  , _context_read          :: STM (Either ApnsTerminationReason ReaderEvent)
  -- ^STM action which dequeues either a reader failure or reader event from the read queue.
  , _context_write         :: H2.EncodeInfo -> H2.FramePayload -> STM (Either ApnsTerminationReason ())
  -- ^STM action which enqueues an HTTP/2 frame to write.
  , _context_encodingTable :: HP.DynamicTable
  -- ^The HPACK dynamic table for encoding.
  , _context_decodingTable :: HP.DynamicTable
  -- ^The HPACK dynamic table for decoding.
  }

-- |The dynamic state of the processing system, passed around as a 'StateT'.
data State = State
  { _state_nextStreamId     :: H2.StreamId
  -- ^The next stream ID to assign to a new push.
  , _state_settings         :: H2.Settings
  -- ^The current settings as accepted and acknowledged by the processor.
  , _state_connectionWindow :: H2.WindowSize
  -- ^How many DATA payload bytes can be written to the connection for any stream before a WINDOW_UPDATE frame from the server is required.
  , _state_writableStreams  :: IntMap WritableStream
  -- ^Streams that are currently writing out their payload data but have had their headers already sent along. Streams will be written out as quickly as
  -- flow-control windows allow.
  , _state_readableStreams  :: IntMap (ApnsPush, ReadableStream)
  -- ^Streams whose request bodies have been fully transmitted via DATA frames and now are waiting for server frames to complete the response.
  }

-- |Data associated with a single push stream which is in the process of being written to the server as DATA frames. Streams are written as fast as
-- flow-control windows allow, so this structure is mostly concerned with tracking that.
data WritableStream = WritableStream
  { _writableStream_push       :: ApnsPush
  -- ^The 'ApnsPush' that this stream is associated with.
  , _writableStream_windowSize :: H2.WindowSize
  -- ^The remaining bytes of payload that can be sent for this stream, assuming the connection flow-control window allows for it.
  -- Each DATA frame that goes out will decrement this by the size of its payload.
  , _writableStream_remaining  :: ByteString
  -- ^The request body content still to be written.
  -- Each DATA frame that goes out will drop the sent bytes from the front of this bytestring.
  }

-- |Data associated with a stream which the processor is waiting for server frames to move along.
data ReadableStream
  = StreamWaiting
  -- ^So far nothing has been received from the server for the stream.
  | StreamReadingHeaderContinuation BL.ByteString
  -- ^A HEADERS frame without the END_HEADERS or END_STREAM flags was received, so the processor is expecting one or more CONTINUATION frames.
  | StreamReadingBody HP.HeaderList BL.ByteString
  -- ^A HEADERS/CONTINUATION with END_HEADERS set but END_STREAM not set was received, so the processor is expecting zero or more DATA frames constituting
  -- the response body.
  | StreamReadingTrailerContinuation HP.HeaderList BL.ByteString BL.ByteString
  -- ^A HEADERS frame after the initial HEADERS frame and zero or more DATA frames was received with the END_STREAM flag but not the END_HEADERS flag, so the
  -- processor is expecting one or more CONTINUATION frames, the last of which will finish the stream.

makeLenses ''Context
makeLenses ''State
makeLenses ''WritableStream
makePrisms ''ReadableStream

-- |The monad stack used within the processing system.
type ProcessorM = ExceptT ApnsTerminationReason (StateT State (ReaderT Context IO))

-- |Emit some debug log message.
processorDebug :: (MonadReader Context m, MonadIO m) => Text -> m ()
processorDebug t = do
  f <- view (context_params . apnsConnectionParams_onDebugLog)
  liftIO $ f t

-- |Enqueue a HTTP/2 frame to be written. Not appropriate for HEADERS/CONTINUATION as there's no guarantee of atomicity for a series of writes.
processorWrite :: H2.EncodeInfo -> H2.FramePayload -> ProcessorM ()
processorWrite ei p = do
  f <- view context_write
  hoist (liftIO . atomically) . ExceptT $ f ei p

-- |Enqueue many frames to be Written as one contiguous block with no gaps, e.g. as for HEADERS/CONTINUATION sequences.
processorWriteMany :: [(H2.EncodeInfo, H2.FramePayload)] -> ProcessorM ()
processorWriteMany frames = do
  f <- view context_write
  hoist (liftIO . atomically) $ traverse_ (ExceptT . uncurry f) $ frames

-- |Invoke some callback function in IO where we don't care at all about exceptions.
invokeWithoutException :: MonadIO m => IO () -> m ()
invokeWithoutException action = liftIO $ handle (\ (_ :: SomeException) -> pure ()) action

-- |Establish a single connection to APNs, yielding @'Right' 'ApnsConnection'@ on success, @'Left' 'ApnsConnectionError'@ otherwise.
connectApns :: forall m. MonadIO m => ApnsConnectionParams -> m (Either ApnsConnectionError ApnsConnection)
connectApns params@(ApnsConnectionParams {..}) =
  liftIO . runExceptT $
    bracketOnError connectSocket (liftIO . Socket.close) $ \ sock -> do
      tlsContext <- liftIO $ TLS.contextNew sock tlsClientParams
      liftIO $ TLS.handshake tlsContext
      liftIO $ TLS.sendData tlsContext (BL.fromStrict H2.connectionPreface)

      ExceptT $ processor params tlsContext sock

  where
    onCertificateRequest _ = do
      pure . Just $
        ( _apnsConnectionParams_clientCertificateChain
        , _apnsConnectionParams_clientCertificateKey
        )

    tlsClientParams =
      (TLS.defaultParamsClient _apnsConnectionParams_hostName (BSC8.pack . show $ _apnsConnectionParams_portNumber))
        { TLS.clientSupported = def
          { TLS.supportedVersions = [TLS.TLS12]
          , TLS.supportedCiphers = ciphersuite_strong
          }
        , TLS.clientHooks = def
          { TLS.onCertificateRequest = onCertificateRequest
          , TLS.onServerCertificate = fromMaybe validateDefault _apnsConnectionParams_onServerCertificate
          , TLS.onSuggestALPN = pure (Just ["h2"])
          }
        , TLS.clientShared = def
          { TLS.sharedCAStore = fromMaybe mempty _apnsConnectionParams_serverCertificateStore
          }
        }

    connectSocket :: ExceptT ApnsConnectionError IO Socket
    connectSocket = do
      tcp <- liftIO $ getProtocolNumber "tcp"
      let hints = Socket.defaultHints
            { Socket.addrFlags      = [Socket.AI_ADDRCONFIG]
            , Socket.addrProtocol   = tcp
            , Socket.addrSocketType = Socket.Stream
            }
      addressInfos <- liftIO $ Socket.getAddrInfo (Just hints) (Just _apnsConnectionParams_hostName) (Just . show $ _apnsConnectionParams_portNumber)

      when (null addressInfos) $
        throwError $ ApnsConnectionErrorInvalidHostName _apnsConnectionParams_hostName

      let go :: [IOException] -> [Socket.AddrInfo] -> ExceptT ApnsConnectionError IO Socket
          go exs [] = throwError $ ApnsConnectionErrorConnectFailed _apnsConnectionParams_hostName exs
          go exs (ai:ais) = do
            let createSocket = liftIO $ Socket.socket (Socket.addrFamily ai) (Socket.addrSocketType ai) (Socket.addrProtocol ai)
            res <- liftIO . try $ bracketOnError createSocket Socket.close $ \ sock ->
              Socket.connect sock (Socket.addrAddress ai) $> sock
            case res of
              Left ex -> go (ex:exs) ais
              Right sock -> pure sock

      go [] addressInfos

-- |Main processing for an APNs connection which sets up the reading and writing threads for exchanging HTTP/2 frames over an established TLS connection,
-- finishes the HTTP/2 connection initiation, and then forks off the asynchronous processing.
processor :: ApnsConnectionParams -> TLS.Context -> Socket -> IO (Either ApnsConnectionError ApnsConnection)
processor params tlsContext sock = do
  let debugLog :: MonadIO n => Text -> n ()
      debugLog = liftIO . view apnsConnectionParams_onDebugLog params

  readerQueue :: TBMQueue ReaderEvent                      <- liftIO . newTBMQueueIO $ view apnsConnectionParams_readQueueSize  params
  writerQueue :: TBMQueue (H2.EncodeInfo, H2.FramePayload) <- liftIO . newTBMQueueIO $ view apnsConnectionParams_writeQueueSize params

  debugLog "Starting reader and writer threads"
  readerAsync <- liftIO . async $ reader (view apnsConnectionParams_onDebugLog params) tlsContext sock readerQueue
  writerAsync <- liftIO . async $ writer (view apnsConnectionParams_onDebugLog params) tlsContext sock writerQueue

  let cleanUpThreads = do
        cancel readerAsync
        cancel writerAsync

  liftIO . atomically $ writeTBMQueue writerQueue (H2.encodeInfo id 0, H2.SettingsFrame [(H2.SettingsEnablePush, 0)])

  debugLog "Waiting for first reader event"
  connectResult <- try $ do
    firstReaderEvent <- liftIO . atomically $ readTBMQueue readerQueue

    case firstReaderEvent of
      Just (ReadSettingsUpdate settings0) -> do
        debugLog "First read event is a valid SETTINGS frame"
        pure $ Right settings0

      Just other -> do
        debugLog $ "First read event is not a valid SETTINGS frame: " <> (pack . show) other
        pure $ Left ApnsConnectionErrorInvalidServerPreface

      Nothing -> do
        debugLog "EOF when reading first frame"
        pure $ Left ApnsConnectionErrorInvalidServerPreface

  pushQueue <- liftIO . newTBMQueueIO $ view apnsConnectionParams_pushQueueSize params
  closingTv <- liftIO . newTVarIO $ Nothing

  case connectResult of
    Left ex -> do
      liftIO cleanUpThreads
      pure . Left $ ApnsConnectionErrorException ex

    Right (Left err) -> do
      liftIO cleanUpThreads
      pure . Left $ err

    Right (Right settings0) -> do
      void . fork $ do
        encodingTable <- liftIO $ HP.newDynamicTableForEncoding HP.defaultDynamicTableSize
        decodingTable <- liftIO $ HP.newDynamicTableForDecoding HP.defaultDynamicTableSize 131072
        let readReaderQueue =
              readTBMQueue readerQueue >>= \ case
                Just a -> pure $ Right a
                Nothing -> Left . either ApnsTerminatedReadError (const $ ApnsTerminatedRemotely (Left "unknown cause")) <$> waitCatchSTM readerAsync
            writeWriterQueue encodeInfo framePayload = do
              isClosedTBMQueue writerQueue >>= \ case
                False -> Right <$> writeTBMQueue writerQueue (encodeInfo, framePayload)
                True -> Left . either ApnsTerminatedWriteError (const $ ApnsTerminatedRemotely (Left "unknown cause")) <$> waitCatchSTM writerAsync

            authority = BSC8.pack $ view apnsConnectionParams_hostName params <> ":" <> show (view apnsConnectionParams_portNumber params)

            context = Context params authority closingTv pushQueue readReaderQueue writeWriterQueue encodingTable decodingTable
            state0 = State 1 settings0 H2.defaultInitialWindowSize mempty mempty

            dropStreams state = do
              let droppedWritableStreams = view state_writableStreams state
                  droppedReadableStreams = view state_readableStreams state

                  dropped :: (v -> ApnsPush) -> H2.StreamId -> v -> IO ()
                  dropped f droppedSid v = do
                    debugLog $ "stream " <> (pack . show) droppedSid <> " dropped at end"
                    invokeWithoutException . _apnsPush_callback (f v) $ ApnsPushDropped

              traverseWithKey_ (dropped _writableStream_push) droppedWritableStreams
              traverseWithKey_ (dropped fst                 ) droppedReadableStreams


        -- enter main processing loop which maintains the connection and eventually exits with some termination reason. Alternates between a write phase
        -- where it tries to write out all stream data it's allowed to and a post-write phase where it waits for incoming frames from the server or new work
        -- to process.
        (try . liftIO . flip runReaderT context . flip runStateT state0 . runExceptT $ processUpdatedSettings settings0 >> postWritePhase False) >>= \ case
          Left ex -> do
            invokeWithoutException . view apnsConnectionParams_onTermination params $ ApnsTerminatedProcessingException ex

          Right (Left reason, state') -> do
            dropStreams state'
            invokeWithoutException . view apnsConnectionParams_onTermination params $ reason

          Right (Right (), state') -> do
            dropStreams state'
            invokeWithoutException . view apnsConnectionParams_onTermination params $ ApnsTerminatedLocally

        liftIO . atomically $ closeTBMQueue pushQueue
        liftIO $ cleanUpThreads

      let submitPush push =
            join . liftIO . atomically $
              (||) <$> isClosedTBMQueue pushQueue <*> (isJust <$> readTVar closingTv) >>= \ case
                False -> pure () <$ writeTBMQueue pushQueue push
                True  -> pure (invokeWithoutException $ _apnsPush_callback push ApnsPushConnectionClosed)

          close = liftIO . atomically $ do
            writeTVar closingTv $ Just ApnsTerminatedLocally
            writeTBMQueue writerQueue (H2.encodeInfo id 0, H2.GoAwayFrame 0 H2.NoError "bye!")

      pure . Right $ ApnsConnection submitPush close

-- |Perform the write phase, writing as many DATA frames as the flow-control windows will allow us
writePhase :: ProcessorM ()
writePhase = do
  go <=< uses state_writableStreams $ toListOf (ifolded . filtered ((> 0) . view writableStream_windowSize) . withIndex)
  postWritePhase False

  where
    -- process a list of writable streams all of which have at least 1 byte available in the flow control window, updating the connection flow control window
    -- as we go and stopping as soon as it's exhausted.
    go :: [(H2.StreamId, WritableStream)] -> ProcessorM ()
    go [] = pure ()
    go ((sid, ws) : wses) = do
      maxFrameSize <- uses state_settings H2.maxFrameSize
      connWindow <- use state_connectionWindow
      processorDebug $ "entering write for " <> (pack . show) sid <> " with connection window " <> (pack . show) connWindow <> " and max frame size " <> (pack . show) maxFrameSize
      unless (connWindow <= 0) $ do
        let toWriteSize = min maxFrameSize . min connWindow . view writableStream_windowSize $ ws
            (toWriteBs, remainingBs) = BS.splitAt toWriteSize . view writableStream_remaining $ ws
            didWriteSize = BS.length toWriteBs

        if BS.null remainingBs
          then do
            processorDebug $ "stream " <> (pack . show) sid <> " finished writing"
            processorWrite (H2.encodeInfo H2.setEndStream sid) (H2.DataFrame toWriteBs)
            assign (state_writableStreams . at sid) Nothing
            assign (state_readableStreams . at sid) (Just (view writableStream_push ws, StreamWaiting))
          else do
            processorDebug $ "stream " <> (pack . show) sid <> " writing " <> (pack . show) toWriteSize <> " bytes with " <> (pack . show) (BS.length remainingBs) <> " bytes to go"
            processorWrite (H2.encodeInfo id sid) (H2.DataFrame toWriteBs)
            modifying (state_writableStreams . at sid . _Just)
              $ over writableStream_windowSize (subtract didWriteSize)
              . set writableStream_remaining remainingBs

        modifying state_connectionWindow (subtract didWriteSize)

        go wses

-- |Perform the post-write phase, where incoming messages, work, and other state changes are processed prior to returning to the write phase
--
-- at this point one of the following conditions is true:
--   the connection flow control window has been exhausted,
--   all stream flow-control windows have been exhausted,
--   all streams have been written out and are waiting for a server response,
--   or there are no pending pushes
-- so now we wait for one of the following things to happen:
--   an incoming SETTINGS frame, which we need to adopt and might change the initial window size and thus all flow-control windows
--   an incoming WINDOW_UPDATE frame, which expands one of the flow-control windows
--   a PING frame which we respond to immediately
--   a PRIORITY frame which we ignore
--   a PUSH_PROMISE frame which we complain about mightily
--   a HEADERS/CONTINUATION/DATA/RST_STREAM frame which advances the read state of some stream
--   a GOAWAY frame which causes us to go into the closing state and signal any dropped pushes as dropped
--
-- The Bool argument indicates whether this 'postWritePhase' follows another post write phase which either adjusted flow-control windows or added streams
-- and thus controls whether this should block waiting for more to do or can immediately enter a write phase as soon as other work has been handled.
postWritePhase :: Bool -> ProcessorM ()
postWritePhase haveUpdatedWindowsOrStreams = do
  activeStreams <- (+)
    <$> uses state_writableStreams length
    <*> uses state_readableStreams length

  canMakeMoreStreams <- uses state_settings (maybe True (activeStreams <) . H2.maxConcurrentStreams)

  processorDebug $ "post write phase with " <> (pack . show) activeStreams <> " active streams. can make more streams? " <> (pack . show) canMakeMoreStreams

  closingTv <- view context_closingTv
  readFunc <- view context_read
  pushQueue <- view context_pushQueue

  -- in an STM transaction figure out what to do based on the reader queue, push queue, closing state, and so on,
  -- choosing an outside of STM action to perform.
  --
  -- this is hella finicky, so a couple of notes:
  --   each branch is <|>ed with each other, and will fall through to the next case if a guard fails or there's nothing in a queue
  --   each branch is of type STM (Bool -> StateT State IO ApnsTerminationReason)
  toDo :: ProcessorM () <- liftIO . atomically $
    readTVar closingTv >>= \ closingMay ->
      -- if there's a frame received to process or no more frames can be received due to reader failure, deal with that
      (   ( readFunc <&> \ case
              Left reason -> throwError reason
              Right event -> processReaderEvent haveUpdatedWindowsOrStreams event )
      -- if we're in the closing state and there are no more active streams, then we're done
      <|> ( case closingMay of
              Just reason -> do
                guard $ activeStreams == 0
                pure $ throwError reason
              Nothing -> retry )
      -- if we're not in the closing state and we've not hit the stream limit, then process a new push that might have arrived
      <|> ( do guard $ not (isJust closingMay) && canMakeMoreStreams
               maybe retry (pure . processNewPush haveUpdatedWindowsOrStreams) =<< readTBMQueue pushQueue )
      -- if there are active streams and we've updated the flow-control windows or streams since the last write phase, then don't block and instead
      -- do a write phase
      <|> ( do guard (activeStreams > 0 && haveUpdatedWindowsOrStreams)
               pure writePhase )
      )

  toDo

-- |Process a reader event in the 'postWritePhase'. This boils down to propagating a failure if the reader failed, adopting and acknowleding new settings if
-- the reader received and processed a SETTINGS frame, or case switching on the received frame and doing various state things based on the frame.
--
-- The Bool is the 'haveUpdatedWindowsOrStreams' flag propagating for this 'postWritePhase'
processReaderEvent :: Bool -> ReaderEvent -> ProcessorM ()
processReaderEvent haveUpdatedWindowsOrStreams = \ case
  ReadH2Error errorCodeId errorData abortReason -> do
    processorDebug $ "reader protocol error " <> (pack . show) errorCodeId <> " " <> (pack . show) errorData <> " " <> (pack . show) abortReason
    nextStreamId <- use state_nextStreamId
    processorWrite (H2.encodeInfo id 0) (H2.GoAwayFrame (pred nextStreamId) errorCodeId errorData)
    throwError abortReason

  ReadFrame frame ->
    processReadFrame haveUpdatedWindowsOrStreams frame

  ReadSettingsUpdate settings' -> do
    windowSizeChanged <- processUpdatedSettings settings'
    postWritePhase $ haveUpdatedWindowsOrStreams || windowSizeChanged

-- |Do the work required when receiving new settings from the server, such as acknowledging the update. This is a separate function since it's used both
-- by the preface and the receive frame processing. Yields True iff the window sizes were updated.
processUpdatedSettings :: H2.Settings -> ProcessorM Bool
processUpdatedSettings settings' = do
  processorDebug $ "read new settings " <> (pack . show) settings'
  settings <- use state_settings
  assign state_settings settings'

  when (H2.headerTableSize settings /= H2.headerTableSize settings') $ do
    processorDebug " - updating encoding table size"
    encodingTable <- view context_encodingTable
    liftIO $ HP.setLimitForEncoding (H2.headerTableSize settings') encodingTable

  let windowSizeChanged = H2.initialWindowSize settings /= H2.initialWindowSize settings'
  when windowSizeChanged $ do
    let delta = H2.initialWindowSize settings' - H2.initialWindowSize settings
    processorDebug $ " - adjusting all stream windows by " <> (pack . show) delta
    modifying (state_writableStreams . each . writableStream_windowSize) (+ delta)

  processorDebug $ " - acknowledging"
  processorWrite (H2.encodeInfo H2.setAck 0) (H2.SettingsFrame [])

  pure windowSizeChanged

-- |Process an incoming frame which is not a SETTINGS frame.
processReadFrame :: Bool -> H2.Frame -> ProcessorM ()
processReadFrame haveUpdatedWindowsOrStreams (H2.Frame (H2.FrameHeader _ flags sid) payload) =
  case payload of
    H2.HeadersFrame _ fragment -> do
      withReadableStream $ \ push -> \ case
        StreamWaiting ->
          case (H2.testEndHeader flags, H2.testEndStream flags) of
            (True,  True)  -> decodeHeaders fragment >>= \ trailers -> processEndStream push trailers ""
            (True,  False) -> decodeHeaders fragment >>= \ headers -> pure . Just $ StreamReadingBody headers ""
            (False, True)  -> pure . Just $ StreamReadingTrailerContinuation [] (BL.fromStrict fragment) ""
            (False, False) -> pure . Just $ StreamReadingHeaderContinuation (BL.fromStrict fragment)
        StreamReadingHeaderContinuation _ ->
          throwError (H2.ProtocolError, "unexpected HEADERS while expecting CONTINUATION")
        StreamReadingBody headers bodyBytes ->
          case (H2.testEndHeader flags, H2.testEndStream flags) of
            (True,  True)  -> decodeHeaders fragment >>= \ trailers -> processEndStream push (headers ++ trailers) bodyBytes
            (True,  False) -> streamError push H2.ProtocolError "unexpected HEADERS without END_STREAM after DATA"
            (False, True)  -> pure . Just $ StreamReadingTrailerContinuation headers (BL.fromStrict fragment) ""
            (False, False) -> streamError push H2.ProtocolError "unexpected HEADERS without END_STREAM after DATA"
        StreamReadingTrailerContinuation _ _ _ ->
          throwError (H2.ProtocolError, "unexpected HEADERS while expecting CONTINUATION")
      postWritePhase haveUpdatedWindowsOrStreams

    H2.ContinuationFrame fragment -> do
      withReadableStream $ \ push -> \ case
        StreamWaiting ->
          throwError (H2.ProtocolError, "unexpected CONTINUATION while expecting HEADERS or DATA")
        StreamReadingHeaderContinuation accumulatedFragments -> do
          let accumulatedFragments' = accumulatedFragments <> BL.fromStrict fragment
          if H2.testEndHeader flags
            then decodeHeaders (BL.toStrict accumulatedFragments') >>= \ headers -> pure . Just $ StreamReadingBody headers ""
            else pure . Just $ StreamReadingHeaderContinuation accumulatedFragments'
        StreamReadingBody _ _ ->
          throwError (H2.ProtocolError, "unexpected CONTINUATION while expecting DATA or HEADERS")
        StreamReadingTrailerContinuation headers accumulatedFragments bodyBytes -> do
          let accumulatedFragments' = accumulatedFragments <> BL.fromStrict fragment
          if H2.testEndHeader flags
            then decodeHeaders (BL.toStrict accumulatedFragments') >>= \ trailers -> processEndStream push (headers ++ trailers) bodyBytes
            else pure . Just $ StreamReadingTrailerContinuation headers accumulatedFragments' bodyBytes
      postWritePhase haveUpdatedWindowsOrStreams

    H2.DataFrame bytes -> do
      withReadableStream $ \ push -> \ case
        StreamWaiting -> do
          if H2.testEndStream flags
            then processEndStream push [] (BL.fromStrict bytes)
            else pure . Just $ StreamReadingBody [] (BL.fromStrict bytes)
        StreamReadingHeaderContinuation _ -> do
          throwError (H2.ProtocolError, "unexpected DATA while expecting CONTINUATION")
        StreamReadingBody headers bodyBytes -> do
          processorDebug $ "received more DATA for stream " <> (pack . show) sid
          let bodyBytes' = bodyBytes <> BL.fromStrict bytes
          if H2.testEndStream flags
            then processEndStream push headers bodyBytes'
            else pure . Just $ StreamReadingBody headers bodyBytes'
        StreamReadingTrailerContinuation _ _ _ ->
          streamError push H2.ProtocolError "unexpected DATA frame after trailing HEADERS sequence"
      postWritePhase haveUpdatedWindowsOrStreams

    H2.RSTStreamFrame errorCodeId -> do
      processorDebug $ "received RST_STREAM for stream " <> (pack . show) sid <> " with " <> (pack . show) errorCodeId
      let terminate push = invokeWithoutException . _apnsPush_callback push $ ApnsPushStreamError errorCodeId "received RST_STREAM from server"
      traverse_ (terminate . _writableStream_push) =<< use (state_writableStreams . at sid)
      traverse_ (terminate . fst)                  =<< use (state_readableStreams . at sid)
      assign (state_writableStreams . at sid) Nothing
      assign (state_readableStreams . at sid) Nothing
      postWritePhase haveUpdatedWindowsOrStreams

    H2.PushPromiseFrame _ _ -> do
      processorDebug "unexpected and unwanted PUSH_PROMISE frame"
      nextStreamId <- use state_nextStreamId
      processorWrite (H2.encodeInfo id 0) (H2.GoAwayFrame (pred nextStreamId) H2.ProtocolError "unwanted PUSH_PROMISE")
      throwError . ApnsTerminatedHttp2Error $ H2.ConnectionError H2.ProtocolError "unwanted PUSH_PROMISE"

    H2.PingFrame bytes -> do
      unless (H2.testAck flags) $ do
        processorDebug "responding to PING"
        processorWrite (H2.encodeInfo H2.setAck 0) (H2.PingFrame bytes)
      postWritePhase haveUpdatedWindowsOrStreams

    H2.GoAwayFrame lastProcessedStreamId errorCodeId errorData -> do
      let decodeGoAway = withObject "GOAWAY frame" $ \ o -> o .: "reason" >>= maybe (fail "unknown reason") pure . apnsErrorReasonFromText
          apnsErrorOrRaw = first (const errorData) $ eitherDecode' (BL.fromStrict errorData) >>= parseEither decodeGoAway
      processorDebug $ "received GOAWAY " <> (pack . show) lastProcessedStreamId <> " " <> (pack . show) errorCodeId <> " " <> (pack . show) errorData
      closingTv <- view context_closingTv
      liftIO . atomically . writeTVar closingTv . Just $ ApnsTerminatedRemotely apnsErrorOrRaw

      (validWritableStreams, droppedWritableStreams) <- uses state_writableStreams (IntMap.split (succ lastProcessedStreamId))
      (validReadableStreams, droppedReadableStreams) <- uses state_readableStreams (IntMap.split (succ lastProcessedStreamId))

      let dropped :: (v -> ApnsPush) -> H2.StreamId -> v -> ProcessorM ()
          dropped f droppedSid v = do
            processorDebug $ "stream " <> (pack . show) droppedSid <> " dropped"
            invokeWithoutException . _apnsPush_callback (f v) $ ApnsPushDropped

      traverseWithKey_ (dropped _writableStream_push) droppedWritableStreams
      traverseWithKey_ (dropped fst                 ) droppedReadableStreams
      assign state_writableStreams validWritableStreams
      assign state_readableStreams validReadableStreams

      postWritePhase haveUpdatedWindowsOrStreams

    H2.WindowUpdateFrame delta -> do
      processorDebug $ "stream " <> (pack . show) sid <> " WINDOW_UPDATE " <> (pack . show) delta

      if sid == 0
        then modifying state_connectionWindow (+ delta)
        else modifying (state_writableStreams . at sid . _Just . writableStream_windowSize) (+ delta)

      postWritePhase True

    other -> do
      processorDebug $ "ignoring unexpected frame " <> (pack . show) other
      postWritePhase haveUpdatedWindowsOrStreams

  where
    withReadableStream :: (ApnsPush -> ReadableStream -> ExceptT (H2.ErrorCodeId, ByteString) ProcessorM (Maybe ReadableStream)) -> ProcessorM ()
    withReadableStream k = use (state_readableStreams . at sid) >>= \ case
      Just (push, state) ->
        runExceptT (k push state) >>= \ case
          Left (errorCodeId, errorData) -> do
            processorDebug $ "while handling a frame for stream " <> (pack . show) sid <> " encountered unrecoverable connection error " <> (pack . show) errorCodeId <> " " <> (pack . show) errorData
            nextStreamId <- use state_nextStreamId
            processorWrite (H2.encodeInfo id 0) (H2.GoAwayFrame (pred nextStreamId) errorCodeId errorData)
            throwError . ApnsTerminatedHttp2Error $ H2.ConnectionError errorCodeId errorData
          Right newStateMay -> do
            assign (state_readableStreams . at sid) ((push,) <$> newStateMay)
      Nothing -> do
        processorDebug $ "unexpected readable stream " <> (pack . show) sid <> ", sending RST"
        processorWrite (H2.encodeInfo id sid) (H2.RSTStreamFrame H2.StreamClosed)

    streamError :: ApnsPush -> H2.ErrorCodeId -> ByteString -> ExceptT (H2.ErrorCodeId, ByteString) ProcessorM (Maybe ReadableStream)
    streamError push errorCodeId errorData = do
      processorDebug $ "stream " <> (pack . show) sid <> " encountered processing error " <> (pack . show) errorCodeId <> " " <> (pack . show) errorData
      lift $ processorWrite (H2.encodeInfo id sid) (H2.RSTStreamFrame errorCodeId)
      invokeWithoutException . _apnsPush_callback push $ ApnsPushStreamError errorCodeId errorData
      pure Nothing

    responseParseError :: ApnsPush -> Text -> ExceptT (H2.ErrorCodeId, ByteString) ProcessorM (Maybe ReadableStream)
    responseParseError push explanation = do
      processorDebug $ "stream " <> (pack . show) sid <> " encountered response parsing error: " <> explanation
      invokeWithoutException . _apnsPush_callback push $ ApnsPushResponseParseError explanation
      pure Nothing

    decodeHeaders :: ByteString -> ExceptT (H2.ErrorCodeId, ByteString) ProcessorM HP.HeaderList
    decodeHeaders headerBlock = do
      decodeTable <- view context_decodingTable
      (try . liftIO $ HP.decodeHeader decodeTable headerBlock) >>= \ case
        Left (ex :: SomeException) -> throwError (H2.CompressionError, "failed to decompress headers: " <> (BSC8.pack . show) ex)
        Right headers              -> pure headers

    processEndStream :: ApnsPush -> HP.HeaderList -> BL.ByteString -> ExceptT (H2.ErrorCodeId, ByteString) ProcessorM (Maybe ReadableStream)
    processEndStream push headers body = either id pure <=< runExceptT $ do
      status <- maybe (throwError (streamError push H2.ProtocolError "missing or invalid :status header")) pure $
        readMaybe . BSC8.unpack =<< lookup ":status" headers

      apnsId <- maybe (throwError (responseParseError push "missing or invalid apns-id header")) pure $
        lookup "apns-id" headers

      if status >= 200 && status <= 299
        then invokeWithoutException . _apnsPush_callback push $ ApnsPushDelivered apnsId
        else do
          (reason, timestamp) <- either (throwError . responseParseError push . pack) pure $
            eitherDecode' body >>= parseEither parseResponse
          invokeWithoutException . _apnsPush_callback push . ApnsPushErrored $ ApnsError apnsId status reason timestamp

      pure Nothing

    parseResponse :: Value -> Parser (Either Text ApnsErrorReason, Maybe UTCTime)
    parseResponse = withObject "APNs response" $ \ obj ->
      (,)
        <$> (obj .: "reason" <&> \ t -> maybe (Left t) Right (apnsErrorReasonFromText t))
        <*> (fmap posixSecondsToUTCTime <$> obj .:? "timestamp")


-- |Process a new 'ApnsPush' by allocating a stream for it, sending its headers, and preparing to write the body data for it, then continuing on with the
-- 'postWritePhase' in progress.
processNewPush :: Bool -> ApnsPush -> ProcessorM ()
processNewPush haveUpdatedWindowsOrStreams push = do
  sid <- use state_nextStreamId
  if sid < 0 || sid >= maxBound - 1
    then do
      processorDebug "cannot process any more pushes on this connection due to stream exhaustion"
      invokeWithoutException $ _apnsPush_callback push ApnsPushStreamsExhausted
      postWritePhase haveUpdatedWindowsOrStreams
    else do
      initialWindowSize <- uses state_settings H2.initialWindowSize
      maxFrameSize <- uses state_settings H2.maxFrameSize
      encodingTable <- view context_encodingTable
      authority <- view context_authority
      let headers = headersForPush authority push
      headerBlockFragments <- liftIO $ encodeHeaderBlockFragments maxFrameSize encodingTable headers

      modifying state_nextStreamId (+2)
      let ws = WritableStream push initialWindowSize $ view (apnsPush_data . apnsPushData_payload) push
      assign (state_writableStreams . at sid) (Just ws)

      processorDebug $ "writing headers for new stream " <> (pack . show) sid <> " with " <> (pack . show) headers <> " in " <> (pack . show) (length headerBlockFragments) <> " header block fragments"

      case preview _Cons headerBlockFragments of
        Just (firstFragment, preview _Snoc -> Just (middleFragments, lastFragment)) -> do
           processorWriteMany
             $  (H2.encodeInfo id sid, H2.HeadersFrame Nothing firstFragment)
             :  map ((H2.encodeInfo id sid,) . H2.ContinuationFrame) middleFragments
             ++ [(H2.encodeInfo H2.setEndHeader sid, H2.ContinuationFrame lastFragment)]

        Just (firstFragment, _) ->
           processorWrite (H2.encodeInfo H2.setEndHeader sid) (H2.HeadersFrame Nothing firstFragment)

        Nothing ->
          -- should never happen, should be at least pseudo headers
          processorWrite (H2.encodeInfo H2.setEndHeader sid) (H2.HeadersFrame Nothing "")

      postWritePhase True

-- |Given an 'ApnsPush', compose the list of headers that should be sent for it.
headersForPush :: ByteString -> ApnsPush -> HP.HeaderList
headersForPush authority (view apnsPush_data -> ApnsPushData {..})
  -- FIXME this doesn't guide the HPACK encoding process at all, but should according to the Apple guidelines, so probably the dynamic table usage is not great
  = (":method", "POST")
  : (":scheme", "https")
  : (":authority", authority)
  : (":path", "/3/device/" <> (BL.toStrict . toLazyByteString . byteStringHex) _apnsPushData_deviceToken)
  : ("apns-expiration", (BSC8.pack . show . (truncate :: NominalDiffTime -> Word32) . utcTimeToPOSIXSeconds) _apnsPushData_expiration)
  : ("apns-topic", encodeUtf8 _apnsPushData_topic)
  : catMaybes
    [ ("apns-priority",)    . BSC8.pack . show <$> _apnsPushData_priority
    , ("apns-collapse-id",)                    <$> _apnsPushData_collapseId
    ]

-- |Given the maximum frame size, a 'HP.HeaderList', and the 'HP.DynamicTable' for encoding, encode a list of headers into a list of header block fragments.
-- The first such fragment gets sent in a HEADERS frame while the subsequent ones if any get sent in a CONTINUATION frame.
encodeHeaderBlockFragments :: Int -> HP.DynamicTable -> HP.HeaderList -> IO [H2.HeaderBlockFragment]
encodeHeaderBlockFragments maxFrameSize dynTbl headers = do
  let maxPackSize = length headers + sumOf (folded . both . to (succ . BS.length)) headers
  headerBlock <- HP.encodeHeader HP.defaultEncodeStrategy maxPackSize dynTbl headers
  let chunk bs
        | (h, t) <- BS.splitAt maxFrameSize bs
        , not (BS.null h) = h : chunk t
        | otherwise       = []
  pure $ chunk headerBlock

-- |Reader thread. Before this exits, some debug log will be emitted, the socket will be shut down for reads, and the reader queue will be closed.
reader :: (Text -> IO ()) -> TLS.Context -> Socket -> TBMQueue ReaderEvent -> IO ()
reader debugLog tlsContext sock readerQueue = do
  res <- try
    $  sourceTls
    $$ decodeH2Frames H2.defaultSettings
    .| CL.iterM (debugLog . ("received: " <>) . pack . show)
    .| sinkTBMQueue readerQueue True

  atomically $ closeTBMQueue readerQueue
  invokeWithoutException $ Socket.shutdown sock Socket.ShutdownReceive

  case res of
    Left (ex :: SomeException) -> do
      debugLog $ "reader ended in exception: " <> (pack . show) ex
      throwIO ex
    Right _ ->
      debugLog "reader ended normally"

  where
    sourceTls :: Producer IO ByteString
    sourceTls =
      liftIO (TLS.recvData tlsContext) >>= \ case
        bs | BS.null bs -> pure ()
           | otherwise  -> yield bs >> sourceTls

    decodeH2Frames :: H2.Settings -> ConduitM ByteString ReaderEvent IO ()
    decodeH2Frames settings = do
      let continue (eventMay, settings') = traverse_ yield eventMay >> decodeH2Frames settings'

      either yield continue <=< runExceptT $ do
        headerBytes <- lift $ BL.toStrict <$> CB.take H2.frameHeaderLength
        when (BS.length headerBytes < H2.frameHeaderLength) $
          bool
            (throwError (ReadH2Error H2.ProtocolError "Insufficient header bytes" ApnsTerminatedInsufficientHeaderBytes))
            (throwError (ReadH2Error H2.StreamClosed "Closed with no data" ApnsTerminatedSilentlyClosed))
            (BS.null headerBytes)

        (frameType, frameHeader) <-
          either (\ h2Error -> throwError $ ReadH2Error (H2.errorCodeId h2Error) (BSC8.pack . show $ h2Error) (ApnsTerminatedHttp2Error h2Error)) pure $
            H2.checkFrameHeader settings (H2.decodeFrameHeader headerBytes)

        when (H2.payloadLength frameHeader > H2.maxFrameSize settings) $
          throwError $ ReadH2Error H2.ProtocolError ("Payload larger than maximum of " <> (BSC8.pack . show) (H2.maxFrameSize settings)) ApnsTerminatedOversizedPayload
        payloadBytes <- lift $ BL.toStrict <$> CB.take (H2.payloadLength frameHeader)
        when (BS.length payloadBytes < H2.payloadLength frameHeader) $
          throwError $ ReadH2Error H2.ProtocolError "Insufficient payload bytes" (ApnsTerminatedInsufficientPayloadBytes frameType)

        payload <-
          either (\ h2Error -> throwError $ ReadH2Error (H2.errorCodeId h2Error) (BSC8.pack $ show h2Error) (ApnsTerminatedHttp2Error h2Error)) pure $
            H2.decodeFramePayload frameType frameHeader payloadBytes

        case payload of
          H2.SettingsFrame _ | H2.testAck (H2.flags frameHeader) ->
            pure (Nothing, settings)

          H2.SettingsFrame settingsList -> do
            for_ (H2.checkSettingsList settingsList) $ \ h2Error ->
              throwError $ ReadH2Error (H2.errorCodeId h2Error) (BSC8.pack $ show h2Error) (ApnsTerminatedHttp2Error h2Error)

            let settings' = H2.updateSettings settings settingsList

            pure (Just (ReadSettingsUpdate settings'), settings')

          other ->
            pure (Just (ReadFrame $ H2.Frame frameHeader other), settings)

-- |Writer thread. Before this exits, some debug log will be emitted, the socket will be shut down for writes, and the writer queue will be closed.
writer :: (Text -> IO ()) -> TLS.Context -> Socket -> TBMQueue (H2.EncodeInfo, H2.FramePayload) -> IO ()
writer debugLog tlsContext sock writerQueue = do
  res <- try
    $  sourceTBMQueue writerQueue
    $$ CL.iterM (debugLog . ("sending: " <>) . pack . show)
    .| CL.concatMap (map BL.fromStrict . uncurry H2.encodeFrameChunks)
    .| awaitForever (TLS.sendData tlsContext)

  atomically $ closeTBMQueue writerQueue
  invokeWithoutException $ do
    TLS.bye tlsContext
    Socket.shutdown sock Socket.ShutdownSend

  case res of
    Left (ex :: SomeException) -> do
      debugLog $ "writer ended in exception: " <> (pack . show) ex
      throwIO ex
    Right _ ->
      debugLog "writer ended normally"

