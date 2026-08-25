{
    description  =  "Plain Emacs harness for developing emacs-vent-out / emacs-vent-in";

    inputs  =  {
        nixpkgs.url  =  "github:NixOS/nixpkgs/nixpkgs-unstable";
    };

    outputs  =  {  self,  nixpkgs  }:
        let
            system  =  "x86_64-linux";
            pkgs  =  import  nixpkgs  {  inherit  system;  };

            #  emacs-vent-out が依存する唯一のパッケージ
            emacsPackages  =  epkgs:  with  epkgs;  [  websocket  ];

            myEmacs  =  (pkgs.emacsPackagesFor  pkgs.emacs).emacsWithPackages  emacsPackages;
        in
        {
            packages.${system}.default  =  myEmacs;

            devShells.${system}.default  =  pkgs.mkShell  {
                buildInputs  =  [  myEmacs  pkgs.websocat  ];

                shellHook  =  ''
                    #  日常使いのemacs-flake設定から隔離する
                    export  HOME_FOR_EMACS="$PWD"

                    e()  {
                            emacs  --init-directory  "$HOME_FOR_EMACS"  -l  "$HOME_FOR_EMACS/init.el"  "$@"
                    }

                    echo  "--------------------------------------------------"
                    echo  "🚀  emacs-vent dev shell (plain, isolated from emacs-flake)"
                    echo  "Emacs Path: $(which emacs)"
                    echo  "--------------------------------------------------"
                    echo  "Type 'e' to launch."
                    echo  "Manual protocol check once running: websocat ws://127.0.0.1:4000/"
                '';
            };
        };
}
