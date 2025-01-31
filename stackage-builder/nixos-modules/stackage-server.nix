# Defines stackage.service, stackage-update.service, and stackage-update.timer.
#
# stackage-update.service runs stackage-server-cron to keep the Stackage website
# up to date.
#
# TODO: As a sort-of experiment, I mixed sops-nix with systemd's LoadCredential
# functionality. I am not sure this was a good idea and would love to have
# someone else comment on it.
#
# Pros:
# * Systemd manages ownership
# * The whole directory of secrets gets passed to the unit
# * It would work with ephemeral users if I used such a thing
#
# Cons:
# * Since sops works at the level of individual secrets, I can't use
#   config.sops.secrets.${secret??}.path if I want to pass the whole directory.
#   The directory is an implementation detail of the name of the secret. So I
#   have to use the literal /run/secrets/, which leaks an implementation detail
#   of sops-nix.
#
#
{ stackage-update-uid, stackage-uid, stackage-server-app }: { pkgs, config, lib, ... }:
let
  name = "stackage-server";
  updateName = "stackage-update";
  mkService =
    { description ? "Stackage server"
    , workDir ? "~"
    , keyName ? "creds_aws_access_fpco"
    , secretName ? "creds_aws_secret_fpco"
    , extraEnvironment ? {}
    , script ? null
    }:
    {
      inherit description;
      wants = [ "postgresql.service" "network.target" ];
      after = [ "postgresql.service" "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = name;
        Restart = "on-failure";
        RestartSec = 1;
        LoadCredential = "creds:/run/secrets/${name}";
        WorkingDirectory = workDir;
      };
      path = [ pkgs.git ];
      environment = {
        PGSTRING = "postgresql://stackage@/stackage";
      } // extraEnvironment;
      preStart = ''
        ln -srf ${stackage-server-app}/run/* .
      '';
      script = if script == null then ''
        # FIXME: Does stackage-server even use these creds?
        export AWS_ACCESS_KEY_ID="$(< "$CREDENTIALS_DIRECTORY/${keyName}")"
        export AWS_SECRET_ACCESS_KEY="$(< "$CREDENTIALS_DIRECTORY/${secretName}")"

        # FIXME: RTS flags copied from FPCo deployment. Maybe not suitable
        # for ours. Note also the server is never idle for 3 seconds, so -I3
        # basically just turns off the idle GC.
        ${stackage-server-app}/bin/stackage-server +RTS -I3 -N1
      '' else script;
    };
in {
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "stackage" ];
    # The following three settings allow both services, running as their
    # own system users, to connect to the db as dbuser "stackage".
    ensureUsers = [
      {
        name = "stackage";
        ensureDBOwnership = true;
      }
    ];
    identMap = ''
      stackage_users ${name} stackage
      stackage_users ${updateName} stackage
    '';
    authentication = ''
      local stackage stackage peer map=stackage_users
    '';
  };
  sops.secrets = {
    "${name}/aws_access_fpco" = {};
    "${name}/aws_secret_fpco" = {};
    "${name}/aws_access_r2" = {};
    "${name}/aws_secret_r2" = {};
    "${name}/r2_endpoint" = {};
    "stackage.org/cloudflare-origin-cert" =
      { owner = config.services.nginx.user; };
    "stackage.org/cloudflare-origin-cert-private-key" =
      { owner = config.services.nginx.user; };
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;
  };

  # STACKAGE SERVER

  users.groups.${name} = {
    gid = stackage-uid;
  };
  users.users.${name} = {
    uid = stackage-uid;
    isNormalUser = true;
    group = name;
    home = "/home/${name}";
    createHome = true;
  };
  systemd.services."${name}" = mkService {
    keyName = "creds_aws_access_r2";
    secretName = "creds_aws_secret_r2";
    extraEnvironment = {
      DOWNLOAD_BUCKET_URL = "https://stackage-haddock.haskell.org";
    };
  };
  services.nginx.virtualHosts =
    let
      stackageProxy = { port ? 3000 }: {
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://localhost:${toString port}";
          recommendedProxySettings = true;
        };
      };
    in {
      "www.stackage.org" = (stackageProxy {}) // {
        sslCertificate = "/run/secrets/stackage.org/cloudflare-origin-cert";
        sslCertificateKey = "/run/secrets/stackage.org/cloudflare-origin-cert-private-key";
      };
    };
  networking.firewall.allowedTCPPorts = [ 22 80 443 ];

  # STACKAGE UPDATER

  users.groups.${updateName} = {
    gid = stackage-update-uid;
  };
  users.users.${updateName} = {
    uid = stackage-update-uid;
    isNormalUser = true;
    group = updateName;
    home = "/home/${updateName}";
    createHome = true;
  };
  systemd.services.${updateName} = {
    description = "Stackage server updater";
    serviceConfig = {
      User = updateName;
      WorkingDirectory = "~";
      LoadCredential = "creds:/run/secrets/${name}";
      Type = "oneshot";
    };
    path = [ pkgs.git ];
    environment = {
      # This access is enabled in the services.postgres section
      PGSTRING = "postgresql://stackage@/stackage";
    };
    preStart = ''
      ln -srf ${stackage-server-app}/run/config $HOME
    '';
    script = ''
      # FIXME: This stack update is a cargo cult from the fpco k8s
      # deployment. I don't know what it's for.
      ${pkgs.stack}/bin/stack update

      export AWS_ACCESS_KEY_ID="$(< "$CREDENTIALS_DIRECTORY/creds_aws_access_r2")"
      export AWS_SECRET_ACCESS_KEY="$(< "$CREDENTIALS_DIRECTORY/creds_aws_secret_r2")"
      export AWS_S3_ENDPOINT="$(< "$CREDENTIALS_DIRECTORY/creds_r2_endpoint")"

      ${stackage-server-app}/bin/stackage-server-cron \
        --cache-cabal-files --log-level info \
        --download-bucket stackage-haddock \
        --upload-bucket stackage-haddock \
        --download-bucket-url https://stackage-haddock.haskell.org
    '';
  };
  systemd.timers.${updateName} = {
    description = "${updateName} trigger";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      Unit = "${updateName}.service";
      OnBootSec = 30;
      # Only fire if the previous run has finished.
      OnUnitInactiveSec = "5 min";
    };
  };
}
