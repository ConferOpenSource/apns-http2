with import <nixpkgs> {};

stdenv.mkDerivation {
  name = "update-build";
  buildInputs = [ haskellPackages.cabal2nix haskellPackages.hpack ];
  buildCommand = "";
}
