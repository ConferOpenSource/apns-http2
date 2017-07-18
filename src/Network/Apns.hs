-- |APNs integration using the HTTP/2 protocol rather than the legacy binary interface.
module Network.Apns
  ( module Network.Apns.Internal
  , module Network.Apns.Types
  ) where

import Network.Apns.Internal (connectApns)
import Network.Apns.Types
