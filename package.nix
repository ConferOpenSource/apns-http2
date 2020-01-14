{ mkDerivation, aeson, aeson-qq, async, base, base16-bytestring
, bytestring, conduit, conduit-extra, containers, data-default
, hpack, http2, keys, lens, lifted-base, mmorph, mtl, network
, stdenv, stm, stm-chans, stm-conduit, text, time, tls, x509
, x509-store, x509-system, x509-validation
}:
mkDerivation {
  pname = "apns-http2";
  version = "0.1.1.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson async base bytestring conduit conduit-extra containers
    data-default http2 keys lens lifted-base mmorph mtl network stm
    stm-chans stm-conduit text time tls x509 x509-store x509-validation
  ];
  libraryToolDepends = [ hpack ];
  executableHaskellDepends = [
    aeson aeson-qq async base base16-bytestring bytestring conduit
    conduit-extra containers data-default http2 keys lens lifted-base
    mmorph mtl network stm stm-chans stm-conduit text time tls x509
    x509-store x509-system x509-validation
  ];
  prePatch = "hpack";
  homepage = "https://github.com/ConferOpenSource/apns-http2#readme";
  description = "Apple Push Notification service HTTP/2 integration";
  license = stdenv.lib.licenses.bsd3;
}
