{
  description = "Development shell for Double Commander";

  inputs = {
    nixpkgs.url = "tarball+https://git.tatikoma.dev/corpix/nixpkgs/archive/corpix.tar.gz";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        lazbuild = pkgs.writeShellScriptBin "lazbuild" ''
          exec ${pkgs.lazarus}/bin/lazbuild \
            --lazarusdir=${pkgs.lazarus}/share/lazarus \
            --pcp="''${DOUBLECMD_LAZARUS_PCP:-''${XDG_CACHE_HOME:-$HOME/.cache}/doublecmd-lazarus}" \
            "$@"
        '';

        runtimeLibs = with pkgs; [
          dbus
          glib
          libx11
          libsForQt5.libqtpas
        ];

        qtPluginPath = "${pkgs.libsForQt5.qtbase.bin}/${pkgs.libsForQt5.qtbase.qtPluginPrefix}";
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            fpc
            getopt
            lazbuild
            lazarus
            pkg-config
          ];

          buildInputs = runtimeLibs;

          nativeBuildInputs = with pkgs; [
            libsForQt5.wrapQtAppsHook
            writableTmpDirAsHomeHook
          ];

          NIX_LDFLAGS = "--as-needed -rpath ${lib.makeLibraryPath runtimeLibs}";
          LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;

          shellHook = ''
            export DOUBLECMD_LAZARUS_PCP="$PWD/.lazarus-nix"
            mkdir -p "$DOUBLECMD_LAZARUS_PCP"

            export QT_PLUGIN_PATH="${qtPluginPath}''${QT_PLUGIN_PATH:+:}$QT_PLUGIN_PATH"
            export QT_QPA_PLATFORM_PLUGIN_PATH="${qtPluginPath}/platforms"

            export lazbuild="$(command -v lazbuild)"
            export LAZARUS_DIR="${pkgs.lazarus}/share/lazarus"

            echo "Double Commander dev shell"
            echo "  lazarus pcp:   $DOUBLECMD_LAZARUS_PCP"
            echo "  build release: ./build.sh release qt5"
            echo "  build debug:   ./build.sh debug qt5"
          '';
        };
      }
    );
}
