{
  description = "Menhir develop environment";

  inputs =
    {
      nixpkgs.url = "nixpkgs/nixos-22.11";
      flake-utils.url = "github:numtide/flake-utils";
    };

  outputs = { self, flake-utils, nixpkgs }:
    flake-utils.lib.eachSystem [ flake-utils.lib.system.x86_64-linux ]
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          dependencies = with pkgs; [
            git
            gnumake
            ninja
            gcc-arm-embedded-10
            cmake
            python311
            picotool
            usbtool
          ];

          usbtool = pkgs.stdenv.mkDerivation
            rec {
              name = "usbtool";
              src = fetchGit {
                url = "https://github.com/avtolstoy/usbtool.git";
                rev = "1fea1151689c0e7336623dd24027a537b3a97237";
              };

              nativeBuildInputs = [
                pkgs.libusb1
                pkgs.pkg-config
              ];

              installPhase = ''
                mkdir -p $out/bin
                cp usbtool $out/bin/usbtool
              '';
            };

          firmwareBuild = (source: pkgs.stdenv.mkDerivation
            rec {
              name = "menhir-rp2040";
              src = source;

              nativeBuildInputs = dependencies;

              dontUseCmakeConfigure = true;
              dontUseNinjaInstall = true;
              buildPhase = ''
                mkdir -p build
                cd build
                cmake -GNinja ..
                ninja
              '';
              installPhase = ''
                mkdir -p $out
                cp menhir.* $out
              '';
            });

          reproducibleBuild = (rev: firmwareBuild (fetchGit {
            url = "ssh://git@github.com/nayarsystems/menhir.git";
            submodules = true;
            allRefs = true;
            rev = rev;
          }));

        in
        rec {
          defaultPackage = packages.local;
          packages.local = firmwareBuild ./.;
          packages.reproducible = reproducibleBuild "960cd7b8bf3b661ae84678897930c4a8e5dbd483";
        });
}
