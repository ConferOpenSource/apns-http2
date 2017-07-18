module Main where

import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)
import Data.Aeson (encode)
import Data.Aeson.QQ (aesonQQ)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BSC8
import qualified Data.ByteString.Lazy as BL
import Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Network.Apns
import Network.TLS (credentialLoadX509Chain)
import System.Environment (getArgs)
import System.X509 (getSystemCertificateStore)
import Text.Read (readMaybe)

main :: IO ()
main = do
  (host, port, certPath, keyPath, deviceToken, topic) <- getArgs >>= \ case
    [h, readMaybe -> Just p, cp, kp, Base16.decode . BSC8.pack -> (dt, dt'), T.pack -> t]
      | BS.null dt' -> pure (h, p, cp, kp, dt, t)
      | otherwise   -> fail "invalid device token"
    _ -> fail "usage: apns-http2-example <host> <port> <cert path> <key path> <device token> <topic>"

  (clientCert, clientKey) <- either fail pure =<< credentialLoadX509Chain certPath [] keyPath

  terminationMv <- newEmptyMVar
  systemCAStore <- getSystemCertificateStore
  let params = ApnsConnectionParams
        { _apnsConnectionParams_hostName               = host
        , _apnsConnectionParams_portNumber             = port
        , _apnsConnectionParams_clientCertificateChain = clientCert
        , _apnsConnectionParams_clientCertificateKey   = clientKey
        , _apnsConnectionParams_serverCertificateStore = Just systemCAStore
        , _apnsConnectionParams_onDebugLog             = TIO.putStrLn . ("Network.Apns debug: " <>)
        , _apnsConnectionParams_onServerCertificate    = Nothing
        -- Uncomment following line and comment previous one to disable server cert verification
        -- , _apnsConnectionParams_onServerCertificate    = Just $ \ _ _ _ _ -> pure []
        , _apnsConnectionParams_onTermination          = putMVar terminationMv
        , _apnsConnectionParams_readQueueSize          = 10
        , _apnsConnectionParams_writeQueueSize         = 10
        , _apnsConnectionParams_pushQueueSize          = 10
        }

  connectApns params >>= \ case
    Left connectError ->
      putStrLn $ "Failed to connect: " <> show connectError
    Right connection -> do
      now <- getCurrentTime
      let _apnsPushData_deviceToken = deviceToken
          _apnsPushData_expiration = addUTCTime (86400*2) now
          _apnsPushData_priority = Nothing
          _apnsPushData_topic = topic
          _apnsPushData_collapseId = Nothing
          _apnsPushData_payload = BL.toStrict $ encode [aesonQQ|
            {
              "aps": {
                "alert": {
                  "title": "Hello, APNs!",
                  "body": "If you're reading this you're too close to a working integration"
                },
                "badge": 1
              }
            }
            |]

      _apnsConnection_submitPush connection $ ApnsPush (ApnsPushData {..}) $ \ res -> do
        putStrLn . ("push result: " <>) . show $ res
        putStrLn "closing connection"
        _apnsConnection_close connection

      terminationReason <- takeMVar terminationMv
      putStrLn . ("Connection terminated: " <>) . show $ terminationReason

