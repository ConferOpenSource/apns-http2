-- |Public types for using the APNs integration.
module Network.Apns.Types
  ( ApnsPushData(..), apnsPushData_deviceToken, apnsPushData_expiration, apnsPushData_priority, apnsPushData_topic, apnsPushData_collapseId, apnsPushData_payload
  , ApnsErrorReason(..), apnsErrorReasonToText, apnsErrorReasonFromText, apnsErrorReasonFromTextMap
  , ApnsError(..), apnsError_apnsId, apnsError_status, apnsError_reason, apnsError_timestamp
  , ApnsPushResult(..), _ApnsPushDelivered, _ApnsPushErrored, _ApnsPushStreamError, _ApnsPushResponseParseError, _ApnsPushDropped, _ApnsPushConnectionClosed
  , _ApnsPushStreamsExhausted
  , ApnsPush(..), apnsPush_data, apnsPush_callback
  , ApnsTerminationReason(..), _ApnsTerminatedLocally, _ApnsTerminatedRemotely, _ApnsTerminatedHttp2Error, _ApnsTerminatedInsufficientHeaderBytes
  , _ApnsTerminatedInsufficientPayloadBytes, _ApnsTerminatedReadError, _ApnsTerminatedWriteError, _ApnsTerminatedProcessingException
  , ApnsConnectionParams(..), apnsConnectionParams_hostName, apnsConnectionParams_portNumber, apnsConnectionParams_clientCertificateChain
  , apnsConnectionParams_clientCertificateKey, apnsConnectionParams_serverCertificateStore, apnsConnectionParams_onDebugLog
  , apnsConnectionParams_onServerCertificate, apnsConnectionParams_onTermination, apnsConnectionParams_readQueueSize, apnsConnectionParams_writeQueueSize
  , apnsConnectionParams_pushQueueSize
  , ApnsConnectionError(..), _ApnsConnectionErrorInvalidHostName, _ApnsConnectionErrorConnectFailed, _ApnsConnectionErrorInvalidServerPreface
  , _ApnsConnectionErrorException
  , ApnsConnection(..), apnsConnection_submitPush, apnsConnection_close
  ) where

import Control.Arrow ((&&&))
import Control.Exception (IOException, SomeException)
import Control.Lens.TH (makeLenses, makePrisms)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.X509 (CertificateChain, PrivKey)
import Data.X509.CertificateStore (CertificateStore)
import Data.X509.Validation (FailedReason, ServiceID)
import Network.HTTP2 (ErrorCodeId, FrameTypeId, HTTP2Error)
import Network.Socket (HostName, PortNumber)
import Network.TLS (ValidationCache)


-- |Data for an APNs push message, consisting of its target device token, information that gets sent as headers with the push request such as expiration and
-- topic, and the payload itself.
data ApnsPushData = ApnsPushData
  { _apnsPushData_deviceToken :: ByteString
  -- ^The target device token, as its raw binary self. This value will be base16 encoded when sending the push message.
  , _apnsPushData_expiration  :: UTCTime
  -- ^When the push should expire at APNs if it hasn't been delivered yet.
  , _apnsPushData_priority    :: Maybe Int
  -- ^What priority the push should have at APNs, with 10 being immediately and must have a alert, sound or badge, and 5 being possibly deferred due to battery
  -- conservation and other factors.
  , _apnsPushData_topic       :: Text
  -- ^The topic (usually app bundle ID) that this push is being sent for.
  , _apnsPushData_collapseId  :: Maybe ByteString
  -- ^An optional identifier that the target device can use to consolidate a series of updates to the same notification.
  , _apnsPushData_payload     :: ByteString
  -- ^The payload data, usually formatted as JSON.
  } deriving (Show)

makeLenses ''ApnsPushData

-- |Various error codes reported by APNs in response to a push or on the connection as a whole. See APNs documentation for meanings.
data ApnsErrorReason
  = ApnsErrorBadCollapseId
  | ApnsErrorBadDeviceToken
  | ApnsErrorBadExpirationDate
  | ApnsErrorBadMessageId
  | ApnsErrorBadPriority
  | ApnsErrorBadTopic
  | ApnsErrorDeviceTokenNotForTopic
  | ApnsErrorDuplicateHeaders
  | ApnsErrorIdleTimeout
  | ApnsErrorMissingDeviceToken
  | ApnsErrorMissingTopic
  | ApnsErrorPayloadEmpty
  | ApnsErrorTopicDisallowed
  | ApnsErrorBadCertificate
  | ApnsErrorBadCertificateEnvironment
  | ApnsErrorExpiredProviderToken
  | ApnsErrorForbidden
  | ApnsErrorInvalidProviderToken
  | ApnsErrorMissingProviderToken
  | ApnsErrorBadPath
  | ApnsErrorMethodNotAllowed
  | ApnsErrorUnregistered
  | ApnsErrorPayloadTooLarge
  | ApnsErrorTooManyProviderTokenUpdates
  | ApnsErrorTooManyRequests
  | ApnsErrorInternalServerError
  | ApnsErrorServiceUnavailable
  | ApnsErrorShutdown
  deriving (Bounded, Enum, Eq, Ord, Show)

makePrisms ''ApnsErrorReason

-- |Convert an 'ApnsErrorReason' to its text equivalent.
apnsErrorReasonToText :: ApnsErrorReason -> Text
apnsErrorReasonToText = \ case
  ApnsErrorBadCollapseId               -> "BadCollapseId"
  ApnsErrorBadDeviceToken              -> "BadDeviceToken"
  ApnsErrorBadExpirationDate           -> "BadExpirationDate"
  ApnsErrorBadMessageId                -> "BadMessageId"
  ApnsErrorBadPriority                 -> "BadPriority"
  ApnsErrorBadTopic                    -> "BadTopic"
  ApnsErrorDeviceTokenNotForTopic      -> "DeviceTokenNotForTopic"
  ApnsErrorDuplicateHeaders            -> "DuplicateHeaders"
  ApnsErrorIdleTimeout                 -> "IdleTimeout"
  ApnsErrorMissingDeviceToken          -> "MissingDeviceToken"
  ApnsErrorMissingTopic                -> "MissingTopic"
  ApnsErrorPayloadEmpty                -> "PayloadEmpty"
  ApnsErrorTopicDisallowed             -> "TopicDisallowed"
  ApnsErrorBadCertificate              -> "BadCertificate"
  ApnsErrorBadCertificateEnvironment   -> "BadCertificateEnvironment"
  ApnsErrorExpiredProviderToken        -> "ExpiredProviderToken"
  ApnsErrorForbidden                   -> "Forbidden"
  ApnsErrorInvalidProviderToken        -> "InvalidProviderToken"
  ApnsErrorMissingProviderToken        -> "MissingProviderToken"
  ApnsErrorBadPath                     -> "BadPath"
  ApnsErrorMethodNotAllowed            -> "MethodNotAllowed"
  ApnsErrorUnregistered                -> "Unregistered"
  ApnsErrorPayloadTooLarge             -> "PayloadTooLarge"
  ApnsErrorTooManyProviderTokenUpdates -> "TooManyProviderTokenUpdates"
  ApnsErrorTooManyRequests             -> "TooManyRequests"
  ApnsErrorInternalServerError         -> "InternalServerError"
  ApnsErrorServiceUnavailable          -> "ServiceUnavailable"
  ApnsErrorShutdown                    -> "Shutdown"

-- |Mapping of 'ApnsErrorReason' text forms to values.
{-# NOINLINE apnsErrorReasonFromTextMap #-}
apnsErrorReasonFromTextMap :: Map Text ApnsErrorReason
apnsErrorReasonFromTextMap = Map.fromList . map (apnsErrorReasonToText &&& id) $ enumFromTo minBound maxBound

-- |Convert a text value to a @Just 'ApnsErrorReason'@ if the text value is a valid error reason, @Nothing@ if it's invalid.
apnsErrorReasonFromText :: Text -> Maybe ApnsErrorReason
apnsErrorReasonFromText = (`Map.lookup` apnsErrorReasonFromTextMap)

-- |Structure carrying error information returned by APNs in response to a push.
data ApnsError = ApnsError
  { _apnsError_apnsId    :: ByteString
  -- ^The unique identifier assigned by APNs for the push.
  , _apnsError_status    :: Int
  -- ^The HTTP status code returned. Should never be in the 2xx range.
  , _apnsError_reason    :: Either Text ApnsErrorReason
  -- ^The reason for failure given by APNs (@Right@) or the raw value of the @reason@ field if its value is unrecognized (@Left@).
  , _apnsError_timestamp :: Maybe UTCTime
  -- ^For status @410@, the last time APNs confirmed that the device token was invalid. No pushes should be sent for this device token.
  } deriving Show

makeLenses ''ApnsError

-- |The result of a push delivery attempt.
data ApnsPushResult
  = ApnsPushDelivered ByteString
  -- ^The push was successfully delivered to APNs along with its assigned @apns-id@. It may or may not be delivered to the target device, at the discretion 
  -- of APNs.
  | ApnsPushErrored ApnsError
  -- ^APNs rejected the push notification. See the 'ApnsError' for more detail.
  | ApnsPushStreamError ErrorCodeId ByteString
  -- ^APNs reset the HTTP/2 stream before delivery could be completed. The push was most likely not accepted by APNs. The HTTP/2 'ErrorCodeId' and error data
  -- are given.
  | ApnsPushResponseParseError Text
  -- ^APNs gave an error response but it could not be parsed as JSON. The JSON parsing error is given.
  | ApnsPushDropped
  -- ^APNs closed the HTTP/2 connection and indicated it did not process the push. It should be resubmitted on a new connection.
  | ApnsPushConnectionClosed
  -- ^The connection to APNs was already closed by the time the push was requested. It should be resubmitted on a new connection.
  | ApnsPushStreamsExhausted
  -- ^The HTTP/2 connection cannot allocate any more new streams. The connection should be closed and the push resubmitted on a new connection.
  deriving Show

makePrisms ''ApnsPushResult

-- |Push notification data along with a callback that's invoked with the disposition of the push as soon as it's known.
data ApnsPush = ApnsPush
  { _apnsPush_data     :: ApnsPushData
  -- ^What data to send for the push.
  , _apnsPush_callback :: ApnsPushResult -> IO ()
  -- ^What callback to invoke when the push result is known. Exceptions thrown by the callback will be silently ignored.
  }

makeLenses ''ApnsPush

-- |The reason an APNs connection was terminated.
data ApnsTerminationReason
  = ApnsTerminatedLocally
  -- ^The APNs connection was locally closed using '_apnsConnection_close'.
  | ApnsTerminatedRemotely (Either ByteString ApnsErrorReason)
  -- ^The APNs connection was remotely closed by APNs. The APNs error reason is given as @Right@ if available, otherwise some other error string 
  -- given as @Left@.
  | ApnsTerminatedHttp2Error HTTP2Error
  -- ^The APNs connection was terminated due to an HTTP/2 protocol error.
  | ApnsTerminatedInsufficientHeaderBytes
  -- ^The APNs connection was terminated because the TCP stream ended before being able to read all the header bytes for an HTTP/2 frame.
  | ApnsTerminatedInsufficientPayloadBytes FrameTypeId
  -- ^The APNs connection was terminated because the TCP stream ended before being able to read all the payload bytes for an HTTP/2 frame.
  | ApnsTerminatedOversizedPayload
  -- ^The APNs connection was terminated because the server send a frame with a purported payload size larger than the currently negotiated MAX_FRAME_SIZE.
  | ApnsTerminatedReadError SomeException
  -- ^The APNs connection was terminated by an I/O error while reading.
  | ApnsTerminatedWriteError SomeException
  -- ^The APNs connection was terminated by an I/O error while writing.
  | ApnsTerminatedProcessingException SomeException
  -- ^The processing thread died due to some unexpected exception. Pushes currently in transit might or might not be delivered.
  deriving Show

makePrisms ''ApnsTerminationReason

-- |Parameters for establishing an APNs connection.
data ApnsConnectionParams = ApnsConnectionParams
  { _apnsConnectionParams_hostName               :: HostName
  -- ^The host name of APNs. Usually @api.development.push.apple.com@ or @api.push.apple.com@.
  , _apnsConnectionParams_portNumber             :: PortNumber
  -- ^The port number of APNs. Usually @443@.
  , _apnsConnectionParams_clientCertificateChain :: CertificateChain
  -- ^The client TLS certificate and chain to send to APNs to authenticate. Usually generated by the Apple developer portal.
  --
  -- See 'Network.TLS.credentialLoadX509Chain' for one way to provide this value.
  , _apnsConnectionParams_clientCertificateKey   :: PrivKey
  -- ^The client TLS private key to use when authenticating with APNs. Usually generated locally and used to generate a certificate signing request which is
  -- then submitted to the Apple developer portal.
  --
  -- See 'Network.TLS.credentialLoadX509Chain' for one way to provide this value.
  , _apnsConnectionParams_serverCertificateStore :: Maybe CertificateStore
  -- ^The certificate store to use when validating the server certificate, typically the system's trusted CA store.
  --
  -- See @getSystemCertificateStore@ from the @x509-system@ package for a method to load the system's trusted CA store, or @readCertificateStore@ from
  -- @x509-store@ for a way to load a custom trusted CA store.
  , _apnsConnectionParams_onDebugLog             :: Text -> IO ()
  -- ^A callback invoked by the APNs library to report debugging information. Set to @\ _ -> pure ()@ for no debug log. Take care to prevent any exceptions
  -- from being thrown as they will likely leave the APNs connection in an undefined state.
  --
  -- WARNING: this will be both verbose and contain potentially sensitive information as it includes all traffic exchanged with APNs, including payloads
  -- and headers. The TLS certificate or key will not be included however.
  , _apnsConnectionParams_onServerCertificate    :: Maybe (CertificateStore -> ValidationCache -> ServiceID -> CertificateChain -> IO [FailedReason])
  -- ^A callback invoked by the TLS library to validate the server's presented certificate. @Nothing@ means use @validateDefault@, which uses
  -- '_apnsConnectionParams_serverCertificateStore' to validate the certificate in the usual way.
  , _apnsConnectionParams_onTermination          :: ApnsTerminationReason -> IO ()
  -- ^A callback invokved by the APNs library when the APNs connection terminates with the reason why it was terminated.
  , _apnsConnectionParams_readQueueSize          :: Int
  -- ^How many HTTP/2 frames to queue. Usually a small number is appropriate as the processing thread does no major blocking.
  , _apnsConnectionParams_writeQueueSize         :: Int
  -- ^How many HTTP/2 frames to queue. Usually a small number is appropriate as the server should direct flow control.
  , _apnsConnectionParams_pushQueueSize          :: Int
  -- ^How many 'ApnsPush' requests to queue. Usually a small number is appropriate.
  }

makeLenses ''ApnsConnectionParams

-- |Indication of reason for an APNs connection attempt failing before the main asynchronous processing could begin.
data ApnsConnectionError
  = ApnsConnectionErrorInvalidHostName HostName
  -- ^The host name given as '_apnsConnectionParams_hostName' was not resolvable.
  | ApnsConnectionErrorConnectFailed HostName [IOException]
  -- ^The host name and port given as '_apnsConnectionParams_hostName' and '_apnsConnectionParams_portNumber' could not be connected to on any of the resolved
  -- addresses. The exceptions generated when connections were attempted are given.
  | ApnsConnectionErrorInvalidServerPreface
  -- ^The server did not initiate with a valid HTTP/2 server preface, defined as a SETTINGS frame. Typically this indicates that the host was not APNs, APNs
  -- is catastrophically down, or something along those lines.
  | ApnsConnectionErrorException SomeException
  -- ^An unexpected error occurred while waiting for the server to complete the HTTP/2 handshake.
  deriving (Show)

makePrisms ''ApnsConnectionError

-- |An established APNs connection. In the future this should get metric and status reporting functions.
data ApnsConnection = ApnsConnection
  { _apnsConnection_submitPush :: ApnsPush -> IO ()
  -- ^Submit a push message. This should never fail immediately and any result of the push attempt should be reported via the '_apnsPush_callback'
  , _apnsConnection_close      :: IO ()
  -- ^Close the APNs connection in an orderly fashion. The '_apnsConnectionParams_onTermination' callback will be triggered with 'ApnsTerminatedLocally'
  -- if the connection closes correctly.
  }

makeLenses ''ApnsConnection
