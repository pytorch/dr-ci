{-# LANGUAGE OverloadedStrings #-}

import           Control.Monad                     (when)
import qualified Data.Maybe                        as Maybe
import           Data.Text                         (Text)
import qualified Data.Vault.Lazy                   as Vault
import qualified Network.OAuth.OAuth2              as OAuth2
import           Network.Wai.Session.ClientSession (clientsessionStore)
import           Options.Applicative
import           System.Environment                (lookupEnv)
import           Text.Read                         (readMaybe)
import           Web.ClientSession                 (getDefaultKey)
import qualified Web.Scotty                        as S

import qualified AuthConfig
import qualified Builds
import qualified Constants
import qualified DbHelpers
import qualified Routes
import qualified Session
import qualified SqlRead
import qualified SqlWrite


data CommandLineArgs = NewCommandLineArgs {
    serverPort                :: Int
  , staticBase                :: String
  , dbHostname                :: String
  , dbUsername                :: String
  , dbPassword                :: String
  , dbMviewUsername           :: String
  , dbMviewPassword           :: String
  , gitHubClientID            :: Text
  , gitHubClientSecret        :: Text
  , gitHubPersonalAccessToken :: Text
  , gitHubWebhookSecret       :: Text
  , runningLocally            :: Bool
  , adminPassword             :: Text
  , noForceSSL                :: Bool
  }


mainAppCode :: CommandLineArgs -> IO ()
mainAppCode args = do

  maybe_envar_port <- lookupEnv "PORT"
  let prt = Maybe.fromMaybe (serverPort args) $ readMaybe =<< maybe_envar_port

  -- TODO get rid of this?
  cache <- Session.initCacheStore
  AuthConfig.initIdps cache github_config

  session <- Vault.newKey
  store <- fmap clientsessionStore getDefaultKey

  let persistence_data = Routes.PersistenceData cache session store


  S.scotty prt $ Routes.scottyApp persistence_data credentials_data

  where
    credentials_data = Routes.SetupData
      static_base
      github_config
      connection_data
      connection_data_mview

    static_base = staticBase args

    access_token = OAuth2.AccessToken $ gitHubPersonalAccessToken args
    github_config = AuthConfig.NewGithubConfig
      (runningLocally args)
      (gitHubClientID args)
      (gitHubClientSecret args)
      access_token
      (gitHubWebhookSecret args)
      (adminPassword args)
      (noForceSSL args)

    databaseName = "loganci"

    connection_data = DbHelpers.NewDbConnectionData {
        DbHelpers.dbHostname = dbHostname args
      , DbHelpers.dbName = databaseName
      , DbHelpers.dbUsername = dbUsername args
      , DbHelpers.dbPassword = dbPassword args
      }

    connection_data_mview = DbHelpers.NewDbConnectionData {
        DbHelpers.dbHostname = dbHostname args
      , DbHelpers.dbName = databaseName
      , DbHelpers.dbUsername = dbMviewUsername args
      , DbHelpers.dbPassword = dbMviewPassword args
      }


myCliParser :: Parser CommandLineArgs
myCliParser = NewCommandLineArgs
  <$> option auto (long "port"      <> value 3001           <> metavar "PORT"
    <> help "Webserver port")
  <*> strOption   (long "data-path" <> value "/data/static" <> metavar "STATIC_DATA"
    <> help "Path to static data files")
  <*> strOption   (long "db-hostname" <> value "localhost" <> metavar "DATABASE_HOSTNAME"
    <> help "Hostname of database")

  <*> strOption   (long "db-username" <> metavar "DATABASE_USER"
    <> help "Username for database user")
  <*> strOption   (long "db-password" <> metavar "DATABASE_PASSWORD"
    <> help "Password for database user")

  <*> strOption   (long "db-mview-username" <> metavar "DATABASE_MVIEW_USER"
    <> help "Username for materialized views database user")
  <*> strOption   (long "db-mview-password" <> metavar "DATABASE_MVIEW_PASSWORD"
    <> help "Password for materialized views database user")

  <*> strOption   (long "github-client-id" <> metavar "GITHUB_CLIENT_ID"
    <> help "Client ID for GitHub app")
  <*> strOption   (long "github-client-secret" <> metavar "GITHUB_CLIENT_SECRET"
    <> help "Client secret for GitHub app")
  <*> strOption   (long "github-personal-access-token" <> metavar "GITHUB_PERSONAL_ACCESS_TOKEN"
    <> help "For debugging purposes. This will be removed eventually")
  <*> strOption   (long "github-webhook-secret" <> metavar "GITHUB_WEBHOOK_SECRET"
    <> help "GitHub webhook secret")
  <*> switch      (long "local"
    <> help "Webserver is being run locally, so don't redirect HTTP to HTTPS")
  <*> strOption   (long "admin-password" <> metavar "ADMIN_PASSWORD"
    <> help "Admin password")
  <*> switch      (long "no-force-ssl"
    <> help "Do not redirect HTTP to HTTPS")

main :: IO ()
main = execParser opts >>= mainAppCode
  where
    opts = info (helper <*> myCliParser)
      ( fullDesc
     <> progDesc "CircleCI failure log analysis webserver"
     <> header "webapp - user frontend" )
