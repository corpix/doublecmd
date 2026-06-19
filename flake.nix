{
  description = "Development shell for Double Commander";

  inputs = {
    nixpkgs.url = "tarball+https://git.tatikoma.dev/corpix/nixpkgs/archive/corpix.tar.gz";
    flake-utils.url = "github:numtide/flake-utils";

    overlay.url = "tarball+https://git.tatikoma.dev/corpix/nixpkgs-overlay/archive/master.tar.gz";
    overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      overlay,
      flake-utils,
    }:
    let
      overlays = [ overlay.overlays.default ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system overlays; };
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

        unrarPackage =
          if pkgs.config.allowUnfree or false then
            pkgs.unrar
          else
            null;

        doublecmd = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "doublecmd";
          version = "dev";

          src = self;

          nativeBuildInputs = with pkgs; [
            fpc
            getopt
            lazarus
            libsForQt5.wrapQtAppsHook
            writableTmpDirAsHomeHook
          ];

          buildInputs = runtimeLibs;

          env.NIX_LDFLAGS = "--as-needed -rpath ${lib.makeLibraryPath finalAttrs.buildInputs}";

          postPatch = ''
            patchShebangs build.sh install/linux/install.sh
            substituteInPlace build.sh \
              --replace-warn '$(which lazbuild)' '"${pkgs.lazarus}/bin/lazbuild --lazarusdir=${pkgs.lazarus}/share/lazarus"'
            substituteInPlace install/linux/install.sh \
              --replace-warn '$DC_INSTALL_PREFIX/usr' '$DC_INSTALL_PREFIX'
            substituteInPlace plugins/wcx/sevenzip/src/platform/sevenziphlp.pas \
              --replace-fail "'/usr/lib/7zip/'" "'${pkgs.p7zip.lib}/lib/p7zip/'"
            substituteInPlace plugins/wcx/sevenzip/src/platform/unix/activex.pas \
              --replace-fail '{.$define Z7_USE_VIRTUAL_DESTRUCTOR_IN_IUNKNOWN}' '{$define Z7_USE_VIRTUAL_DESTRUCTOR_IN_IUNKNOWN}'
          '';

          buildPhase = ''
            runHook preBuild

            ./build.sh release qt5

            runHook postBuild
          '';

          postBuild = ''
            dcLazbuild() {
              lazbuild \
                --lazarusdir=${pkgs.lazarus}/share/lazarus \
                --widgetset=qt5 \
                "$@"
            }

            dcLazbuild plugins/wcx/torrent/src/torrent.lpi
            dcLazbuild plugins/wdx/textline/src/TextLine.lpi

            echo "=== produced plugin artifacts ==="
            find plugins -type f \
              \( -name '*.wcx' -o -name '*.wdx' -o -name '*.wfx' \
                 -o -name '*.wlx' -o -name '*.dsx' \) -print | sort
            echo "================================="
          '';

          installPhase = ''
            runHook preInstall

            install/linux/install.sh -I $out

            runHook postInstall
          '';

          postInstall = ''
            pluginDir=$(echo "$out"/lib*/doublecmd/plugins)

            while IFS= read -r artifact; do
              base=$(basename "$artifact")
              ext=''${base##*.}
              name=''${base%.*}
              if [ -z "$(find "$pluginDir/$ext" -name "$base" 2>/dev/null)" ]; then
                echo "installing missing plugin: $base -> $pluginDir/$ext/$name/"
                install -Dm644 "$artifact" "$pluginDir/$ext/$name/$base"
              fi
            done < <(find plugins -type f \
              \( -name '*.wcx' -o -name '*.wdx' -o -name '*.wfx' \
                 -o -name '*.wlx' -o -name '*.dsx' \))
          '';

          preFixup = ''
            qtWrapperArgs+=(
              --prefix LD_LIBRARY_PATH : ${
                lib.makeLibraryPath (
                  [
                    pkgs.libssh2
                    pkgs.openssl
                  ]
                  ++ lib.optional (unrarPackage != null) unrarPackage
                )
              }
              --prefix PATH : ${lib.makeBinPath [ pkgs.aria2 ]}
            )
          '';

          meta = {
            homepage = "https://doublecmd.sourceforge.io/";
            description = "Two-panel graphical file manager written in Pascal";
            license = lib.licenses.gpl2Plus;
            mainProgram = "doublecmd";
            maintainers = [ ];
            platforms = lib.platforms.linux;
          };
        });
      in
      {
        packages = {
          inherit doublecmd;
          default = doublecmd;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            fpc
            getopt
            lazbuild
            lazarus
            pkg-config
            pascal-language-server
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
            export PP="${pkgs.fpc}/bin/fpc"
            export FPCDIR="${pkgs.lazarus}/share/fpcsrc"
            export LAZARUSDIR="${pkgs.lazarus}/share/lazarus"
            export LAZARUS_DIR="${pkgs.lazarus}/share/lazarus"
            export FPCTARGET="${pkgs.stdenv.hostPlatform.parsed.kernel.name}"
            export FPCTARGETCPU="${pkgs.stdenv.hostPlatform.parsed.cpu.name}"

            echo "Double Commander dev shell"
            echo "  lazarus pcp:   $DOUBLECMD_LAZARUS_PCP"
            echo "  build release: ./build.sh release qt5"
            echo "  build debug:   ./build.sh debug qt5"
          '';
        };
      }
    );
}
