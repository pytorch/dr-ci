{-# LANGUAGE OverloadedStrings #-}

import           Control.Applicative               ((<|>))
import           Control.Monad                     (unless, when)
import           Control.Monad.IO.Class            (liftIO)
import           Control.Monad.Trans.Except        (ExceptT (ExceptT), except,
                                                    runExceptT)
import           Data.Bifunctor                    (first)
import qualified Data.ByteString.Lazy.Char8        as LBSC
import           Data.Default                      (def)
import           Data.Either.Utils                 (maybeToEither)
import           Data.Functor                      (($>))
import           Data.List                         (filter)
import           Data.List.Split                   (splitOn)
import qualified Data.Maybe                        as Maybe
import           Data.String                       (fromString)
import           Data.Text                         (Text)
import qualified Data.Text                         as T
import qualified Data.Text.Lazy                    as LT
import qualified Data.Vault.Lazy                   as Vault
import qualified Network.OAuth.OAuth2              as OAuth2
import           Network.Wai
import           Network.Wai.Middleware.ForceSSL   (forceSSL)
import           Network.Wai.Middleware.Static     hiding ((<|>))
import           Network.Wai.Session               (Session, SessionStore,
                                                    withSession)
import           Network.Wai.Session.ClientSession (clientsessionStore)
import           Options.Applicative
import           System.Environment                (lookupEnv)
import           System.FilePath
import           Text.Read                         (readMaybe)
import           Web.ClientSession                 (getDefaultKey)
import qualified Web.Scotty                        as S
import qualified Web.Scotty.Internal.Types         as ScottyTypes

import qualified Auth
import qualified AuthConfig
import qualified AuthStages
import qualified Breakages
import qualified Breakages2
import qualified Builds
import qualified Constants
import qualified DbHelpers
import qualified DbInsertion
import qualified GitRev
import qualified JsonUtils
import qualified MatchOccurrences
import qualified Pagination
import qualified Pagination
import qualified Scanning
import qualified ScanPatterns
import qualified Session
import qualified SqlRead
import qualified SqlUpdate
import qualified SqlWrite
import qualified StatusUpdate
import qualified Types
import qualified WebApi


checkboxIsTrue :: Text -> Bool
checkboxIsTrue = (== ("true" :: Text))


data MutablePatternParms = MutablePatternParms {
    pat_is_nondeterminisitc :: Bool
  , pat_description         :: Text
  , pat_tags_raw_text       :: String
  , pat_specificity         :: Int
  }


getMutablePatternParms :: ScottyTypes.ActionT LT.Text IO MutablePatternParms
getMutablePatternParms = do
  is_nondeterministic <- checkboxIsTrue <$> S.param "is_nondeterministic"
  description <- S.param "description"
  specificity <- S.param "specificity"
  tags <- S.param "tags"
  return $ MutablePatternParms
    is_nondeterministic
    description
    tags
    specificity


patternFromParms :: ScottyTypes.ActionT LT.Text IO ScanPatterns.Pattern
patternFromParms = do

  mutable_pattern_parms <- getMutablePatternParms

  expression <- S.param "pattern"
  is_regex <- checkboxIsTrue <$> S.param "is_regex"

  use_lines_from_end <- checkboxIsTrue <$> S.param "use_lines_from_end"
  applicable_steps <- S.param "applicable_steps"

  let match_expression = ScanPatterns.toMatchExpression is_regex expression $ pat_is_nondeterminisitc mutable_pattern_parms

  lines_from_end <- if use_lines_from_end
    then Just <$> S.param "lines_from_end"
    else return Nothing

  return $ ScanPatterns.NewPattern
    match_expression
    (pat_description mutable_pattern_parms)
    (clean_list $ pat_tags_raw_text mutable_pattern_parms)
    (clean_list applicable_steps)
    (pat_specificity mutable_pattern_parms)
    False
    lines_from_end
  where
    clean_list = filter (not . T.null) . map (T.strip . T.pack) . splitOn ";"


data SetupData = SetupData {
    _setup_static_base     :: String
  , _setup_github_config   :: AuthConfig.GithubConfig
  , _setup_connection_data :: DbHelpers.DbConnectionData
  }


data PersistenceData = PersistenceData {
    _setup_cache   :: Types.CacheStore
  , _setup_session :: Vault.Key (Session IO String String)
  , _setup_store   :: SessionStore IO String String
  }


validateMaybeRevision :: LT.Text -> ScottyTypes.ActionT LT.Text IO (Either Text (Maybe GitRev.GitSha1))
validateMaybeRevision key = do
  implicated_revision <- S.param key
  return $ if T.null implicated_revision
    then Right Nothing
    else do
      validated_revision <- GitRev.validateSha1 implicated_revision
      return $ Just validated_revision


echoEndpoint :: S.ScottyM ()
echoEndpoint = S.post "/api/echo" $ do
  body <- S.body
  headers <- S.headers

  liftIO $ do
    putStrLn "===== HEADERS ===="
    mapM_ (\(x, y) -> putStrLn $ LT.unpack $ x <> ": " <> y) headers
    putStrLn "== END HEADERS ==="
    putStrLn "====== BODY ======"
    putStrLn $ LBSC.unpack body
    putStrLn "==== END BODY ===="


retrieveLogContext ::
     Vault.Key (Session IO String String)
  -> AuthConfig.GithubConfig
  -> DbHelpers.DbConnectionData
  -> ScottyTypes.ActionT LT.Text IO ()
retrieveLogContext session github_config connection_data = do
  match_id <- S.param "match_id"
  context_linecount <- S.param "context_linecount"

  let callback_func :: AuthStages.Username -> IO (Either Text SqlRead.LogContext)
      callback_func _user_alias = SqlRead.log_context_func
        connection_data
        (MatchOccurrences.MatchId match_id)
        context_linecount

  rq <- S.request
  either_log_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
  S.json $ WebApi.toJsonEither either_log_result


scottyApp :: PersistenceData -> SetupData -> ScottyTypes.ScottyT LT.Text IO ()
scottyApp (PersistenceData cache session store) (SetupData static_base github_config connection_data) = do

    S.middleware $ withSession store (fromString "SESSION") def session

    S.middleware $ staticPolicy $ noDots >-> addBase static_base

    unless (AuthConfig.is_local github_config) $
      S.middleware $ forceSSL


    -- For debugging only
    when (AuthConfig.is_local github_config) echoEndpoint


    S.post "/api/github-event" $ StatusUpdate.github_event_endpoint connection_data github_config



    -- Experimental
    S.post "/api/report-breakage" $ do

      either_maybe_implicated_revision <- validateMaybeRevision "implicated_revision"
      notes <- S.param "notes"
      is_broken <- S.param "is_broken"
      step_id <- S.param "step_id"

      rq <- S.request
      insertion_result <- liftIO $ runExceptT $ do
        maybe_implicated_revision <- except $ first AuthStages.DbFailure either_maybe_implicated_revision

        let callback_func user_alias = SqlWrite.api_new_breakage_report connection_data breakage_report
              where
                breakage_report = Breakages.NewBreakageReport
                  (Builds.NewBuildStepId step_id)
                  (GitRev.sha1 <$> maybe_implicated_revision)
                  is_broken
                  notes
                  user_alias

        ExceptT $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result



    S.post "/api/code-breakage-resolution-report" $ do

      sha1 <- S.param "sha1"
      cause_ids_delimited <- S.param "causes"

      let clean_list = filter (not . T.null) . map (T.strip . T.pack) . splitOn ";"
          cause_id_list = map read $ map T.unpack $ clean_list cause_ids_delimited

      rq <- S.request
      insertion_result <- liftIO $ runExceptT $ do

        let callback_func user_alias = do
              insertion_eithers <- mapM (SqlWrite.api_code_breakage_resolution_insert connection_data . gen_resolution_report) cause_id_list
              return $ sequenceA insertion_eithers
              where
                gen_resolution_report cause_id = Breakages2.NewResolutionReport
                  sha1
                  cause_id
                  user_alias

        ExceptT $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result


    S.post "/api/code-breakage-cause-report" $ do

      sha1 <- S.param "sha1"
      description <- S.param "description"
      jobs_delimited <- S.param "jobs"

      let clean_list = filter (not . T.null) . map (T.strip . T.pack) . splitOn ";"
          jobs_list = clean_list jobs_delimited


      rq <- S.request
      insertion_result <- liftIO $ runExceptT $ do

        let callback_func user_alias = SqlWrite.api_code_breakage_cause_insert connection_data breakage_report jobs_list
              where
                breakage_report = Breakages2.NewBreakageReport
                  sha1
                  description
                  user_alias

        ExceptT $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result



    S.post "/api/rescan-build" $ do

      build_number <- S.param "build"

      let callback_func :: AuthStages.Username -> IO (Either (AuthStages.BackendFailure Text) Text)
          callback_func user_alias = do
            Scanning.rescanSingleBuild
              connection_data
              user_alias
              (Builds.NewBuildNumber build_number)
            return $ Right "Scan complete."

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result


    S.post "/api/rescan-commit" $ do

      commit_sha1_text <- S.param "sha1"

      let owned_repo = DbHelpers.OwnerAndRepo Constants.project_name Constants.repo_name

          callback_func :: AuthStages.Username -> IO (Either (AuthStages.BackendFailure Text) Text)
          callback_func user_alias = do
            maybe_previously_posted_status <- liftIO $ SqlRead.get_posted_github_status connection_data owned_repo commit_sha1_text

            run_result <- runExceptT $
              StatusUpdate.handleFailedStatuses
                connection_data
                (AuthConfig.personal_access_token github_config)
                (Just user_alias)
                owned_repo
                commit_sha1_text
                maybe_previously_posted_status

            putStrLn $ "Run result: " ++ show run_result
            return $ first (AuthStages.DbFailure . LT.toStrict) $ run_result $> "Finished scan"

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result


    S.post "/api/populate-master-commits" $ do
      body_json <- S.jsonData
      maybe_auth_header <- S.header "token"

      insertion_result <- liftIO $ runExceptT $ do
          auth_token <- except $ maybeToEither (T.pack "Need \"token\" header!") maybe_auth_header
          when (LT.toStrict auth_token /= AuthConfig.admin_password github_config) $
            except $ Left $ T.pack "Incorrect admin password"
          ExceptT $ SqlWrite.store_master_commits connection_data body_json

      S.json $ WebApi.toJsonEither insertion_result


    -- TODO
    S.post "/api/update-master-commits" $
      S.json ("TODO" :: String)



    -- TODO FINISH ME
    {-
    S.post "/api/new-pattern-replace" $ do

      new_pattern <- patternFromParms
      let callback_func user_alias = do
            conn <- DbHelpers.get_connection connection_data
            SqlWrite.copy_pattern xxx

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ DbInsertion.toInsertionResponse github_config insertion_result
    -}



    S.post "/api/new-pattern-insert" $ do

      new_pattern <- patternFromParms
      let callback_func user_alias = do
            conn <- DbHelpers.get_connection connection_data
            SqlWrite.api_new_pattern conn $ Left (new_pattern, user_alias)

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ DbInsertion.toInsertionResponse github_config insertion_result


    -- XXX IMPORTANT:
    -- The session cookie is specific to the parent dir of the path.
    -- So with the path "/api/callback", only HTTP accesses to paths
    -- at or below the "/api/" path will be members of the same session.
    -- Consequentially, a cookie set (namely, the github access token)
    -- in a request to a certain path will only be accessible to
    -- other requests at or below that same parent directory.
    S.get "/api/github-auth-callback" $ do
      rq <- S.request
      let Just (_sessionLookup, sessionInsert) = Vault.lookup session $ vault rq
      Auth.callbackH cache github_config $ sessionInsert Auth.githubAuthTokenSessionKey

    S.get "/logout" $ Auth.logoutH cache

    S.get "/api/status-posted-commits-by-day" $
      S.json =<< liftIO (SqlRead.api_status_posted_commits_by_day connection_data)

    S.get "/api/status-postings-by-day" $
      S.json =<< liftIO (SqlRead.api_status_postings_by_day connection_data)

    S.get "/api/failed-commits-by-day" $
      S.json =<< liftIO (SqlRead.api_failed_commits_by_day connection_data)

    {-
    S.get "/api/is-ancestor" $ do
      ancestor_sha1_text <- S.param "ancestor"
      ancestor_sha1_text <- S.param "descendent"

      S.json =<< liftIO (SqlRead.api_jobs connection_data)
    -}

    S.get "/api/test-failures" $ do
      pattern_id <- S.param "pattern_id"
      S.json =<< liftIO (do
        either_items <- SqlRead.api_test_failures connection_data $ ScanPatterns.PatternId pattern_id
        return $ WebApi.toJsonEither either_items)

    S.get "/api/posted-statuses" $ do
      count <- S.param "count"
      S.json =<< liftIO (SqlRead.api_posted_statuses connection_data count)

    S.get "/api/aggregate-posted-statuses" $ do
      count <- S.param "count"
      S.json =<< liftIO (SqlRead.api_aggregate_posted_statuses connection_data count)

    S.get "/api/list-commit-jobs" $ do
      sha1 <- S.param "sha1"
      S.json =<< liftIO (SqlRead.api_commit_jobs connection_data $ Builds.RawCommit sha1)

    S.get "/api/job" $
      S.json =<< liftIO (SqlRead.api_jobs connection_data)

    S.get "/api/log-storage-stats" $
      S.json =<< liftIO (SqlRead.api_storage_stats connection_data)

    S.get "/api/log-size-histogram" $
      S.json =<< liftIO (SqlRead.api_byte_count_histogram connection_data)

    S.get "/api/log-lines-histogram" $
      S.json =<< liftIO (SqlRead.api_line_count_histogram connection_data)

    S.get "/api/master-timeline" $ do
      offset_count <- S.param "offset"
      starting_commit <- S.param "sha1"
      use_sha1_offset <- S.param "use_sha1_offset"

      let offset_mode = if checkboxIsTrue use_sha1_offset
            then Pagination.Commit $ Builds.RawCommit starting_commit
            else Pagination.Count offset_count

      commit_count <- S.param "count"

      json_result <- liftIO $ SqlRead.api_master_builds connection_data $ Pagination.OffsetLimit offset_mode commit_count
      S.json json_result

    S.get "/api/step" $
      S.json =<< liftIO (SqlRead.api_step connection_data)

    S.get "/api/commit-info" $ do
      commit_sha1_text <- S.param "sha1"
      json_result <- liftIO $ runExceptT $ do
        sha1 <- except $ GitRev.validateSha1 commit_sha1_text
        ExceptT $ SqlUpdate.count_revision_builds connection_data (AuthConfig.personal_access_token github_config) sha1

      S.json $ WebApi.toJsonEither json_result

    S.get "/api/commit-builds" $ do
      commit_sha1_text <- S.param "sha1"
      json_result <- runExceptT $ do
        sha1 <- except $ GitRev.validateSha1 commit_sha1_text
        liftIO $ SqlRead.get_revision_builds connection_data sha1

      S.json $ WebApi.toJsonEither json_result

    S.get "/api/new-pattern-test" $ do
      liftIO $ putStrLn "Testing pattern..."
      buildnum <- S.param "build_num"
      new_pattern <- patternFromParms
      S.json =<< liftIO (do
        foo <- SqlRead.api_new_pattern_test connection_data (Builds.NewBuildNumber buildnum) new_pattern
        return $ WebApi.toJsonEither foo)

    S.get "/api/tag-suggest" $ do
      term <- S.param "term"
      S.json =<< liftIO (SqlRead.api_autocomplete_tags connection_data term)

    S.get "/api/step-suggest" $ do
      term <- S.param "term"
      S.json =<< liftIO (SqlRead.api_autocomplete_steps connection_data term)

    S.get "/api/step-list" $
      S.json =<< liftIO (SqlRead.api_list_steps connection_data)

    S.get "/api/branch-suggest" $ do
      term <- S.param "term"
      S.json =<< liftIO (SqlRead.api_autocomplete_branches connection_data term)

    S.get "/api/random-scannable-build" $
      S.json =<< liftIO (SqlRead.api_random_scannable_build connection_data)

    S.get "/api/summary" $
      S.json =<< liftIO (SqlRead.api_summary_stats connection_data)

    S.get "/api/unmatched-builds" $
      S.json =<< liftIO (SqlRead.api_unmatched_builds connection_data)

    S.get "/api/unmatched-builds-for-commit" $ do
      commit_sha1_text <- S.param "sha1"
      S.json =<< liftIO (SqlRead.api_unmatched_commit_builds connection_data commit_sha1_text)

    S.get "/api/idiopathic-failed-builds" $
      S.json =<< liftIO (SqlRead.api_idiopathic_builds connection_data)

    S.get "/api/idiopathic-failed-builds-for-commit" $ do
      commit_sha1_text <- S.param "sha1"
      S.json =<< liftIO (SqlRead.api_idiopathic_commit_builds connection_data commit_sha1_text)

    S.get "/api/timed-out-builds-for-commit" $ do
      commit_sha1_text <- S.param "sha1"
      S.json =<< liftIO (SqlRead.api_timeout_commit_builds connection_data commit_sha1_text)

    -- | Access-controlled endpoint
    S.get "/api/view-log-context" $ retrieveLogContext session github_config connection_data


    S.get "/api/view-log-full" $ do
      build_id <- S.param "build_id"

      let callback_func :: AuthStages.Username -> IO (Either Text Text)
          callback_func _user_alias = do
            conn <- DbHelpers.get_connection connection_data
            maybe_log <- SqlRead.read_log conn $ Builds.NewBuildNumber build_id
            return $ maybeToEither "log not in database" maybe_log

      rq <- S.request
      either_log_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      case either_log_result of
        Right logs  -> S.text $ LT.fromStrict logs
        Left errors -> S.html $ LT.fromStrict $ JsonUtils._message $ JsonUtils.getDetails errors


    S.get "/api/pattern" $ do
      pattern_id <- S.param "pattern_id"
      S.json =<< liftIO (SqlRead.api_single_pattern connection_data $ ScanPatterns.PatternId pattern_id)

    S.get "/api/patterns-dump" $
      S.json =<< liftIO (SqlRead.dump_patterns connection_data)

    -- XXX This is the deprecated kind of breakage report
    S.get "/api/breakages-dump" $
      S.json =<< liftIO (SqlRead.dump_breakages connection_data)

    S.get "/api/presumed-stable-branches-dump" $
      S.json =<< liftIO (SqlRead.dump_presumed_stable_branches connection_data)

    S.post "/api/pattern-specificity-update" $ do
      pattern_id <- S.param "pattern_id"
      specificity <- S.param "specificity"
      let callback_func _user_alias = SqlWrite.update_pattern_specificity connection_data (ScanPatterns.PatternId pattern_id) specificity

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result

    S.post "/api/pattern-description-update" $ do
      pattern_id <- S.param "pattern_id"
      description <- S.param "description"
      let callback_func _user_alias = SqlWrite.update_pattern_description connection_data (ScanPatterns.PatternId pattern_id) description

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result

    S.post "/api/pattern-tag-add" $ do
      pattern_id <- S.param "pattern_id"
      tag <- S.param "tag"
      let callback_func _user_alias = SqlWrite.add_pattern_tag connection_data (ScanPatterns.PatternId pattern_id) tag

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result

    S.post "/api/pattern-tag-remove" $ do
      pattern_id <- S.param "pattern_id"
      tag <- S.param "tag"
      let callback_func _user_alias = SqlWrite.remove_pattern_tag connection_data (ScanPatterns.PatternId pattern_id) tag

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result


    S.post "/api/patterns-restore" $ do
      body_json <- S.jsonData

      let callback_func _user_alias = SqlWrite.restore_patterns connection_data body_json

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result

    S.get "/api/code-breakages" $ do
      S.json =<< liftIO (SqlRead.api_all_code_breakages connection_data)


    S.post "/api/code-breakage-description-update" $ do
      item_id <- S.param "cause_id"
      description <- S.param "description"
      let callback_func _user_alias = SqlWrite.update_code_breakage_description connection_data item_id description

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result


    S.post "/api/code-breakage-delete" $ do
      item_id <- S.param "cause_id"
      let callback_func _user_alias = SqlWrite.delete_code_breakage connection_data item_id

      rq <- S.request
      insertion_result <- liftIO $ Auth.getAuthenticatedUser rq session github_config callback_func
      S.json $ WebApi.toJsonEither insertion_result



    -- XXX This is the deprecated kind of breakage report
    S.get "/api/commit-breakage-reports" $ do
      commit_sha1_text <- S.param "sha1"
      S.json =<< liftIO (SqlRead.api_commit_breakage_reports connection_data commit_sha1_text)

    S.get "/api/patterns-timeline" $
      S.json =<< liftIO (SqlRead.api_pattern_occurrence_timeline connection_data)

    S.get "/api/patterns" $
      S.json =<< liftIO (SqlRead.api_patterns connection_data)

    S.get "/api/patterns-branch-filtered" $ do
      branches <- S.param "branches"
      liftIO $ putStrLn $ "Got branch list: " ++ show branches
      S.json =<< liftIO (SqlRead.api_patterns_branch_filtered connection_data branches)

    S.get "/api/single-build-info" $ do
      build_id <- S.param "build_id"
      result <- liftIO (SqlUpdate.get_build_info connection_data (AuthConfig.personal_access_token github_config) $ Builds.NewBuildNumber build_id)
      S.json $ WebApi.toJsonEither result

    S.get "/api/best-build-match" $ do
      build_id <- S.param "build_id"
      S.json =<< liftIO (SqlRead.get_best_build_match connection_data $ Builds.NewBuildNumber build_id)

    S.get "/api/build-pattern-matches" $ do
      build_id <- S.param "build_id"
      S.json =<< liftIO (SqlRead.get_build_pattern_matches connection_data $ Builds.NewBuildNumber build_id)

    S.get "/api/best-pattern-matches" $ do
      pattern_id <- S.param "pattern_id"
      S.json =<< liftIO (SqlRead.get_best_pattern_matches connection_data $ ScanPatterns.PatternId pattern_id)

    S.get "/api/pattern-matches" $ do
      pattern_id <- S.param "pattern_id"
      S.json =<< liftIO (SqlRead.get_pattern_matches connection_data $ ScanPatterns.PatternId pattern_id)

    S.get "/favicon.ico" $ do
      S.setHeader "Content-Type" "image/x-icon"
      S.file $ static_base </> "images/favicon.ico"

    S.options "/" $ do
      S.setHeader "Access-Control-Allow-Origin" "*"
      S.setHeader "Access-Control-Allow-Methods" "POST, GET, OPTIONS"

    S.get "/" $ do
      S.setHeader "Content-Type" "text/html; charset=utf-8"
      S.file $ static_base </> "index.html"


mainAppCode :: CommandLineArgs -> IO ()
mainAppCode args = do

  maybe_envar_port <- lookupEnv "PORT"
  let prt = Maybe.fromMaybe (serverPort args) $ readMaybe =<< maybe_envar_port
  putStrLn $ "Listening on port " <> show prt

  -- TODO get rid of this
  cache <- Session.initCacheStore
  AuthConfig.initIdps cache github_config

  session <- Vault.newKey
  store <- fmap clientsessionStore getDefaultKey

  let persistence_data = PersistenceData cache session store





  when (AuthConfig.is_local github_config) $ do
    -- XXX FOR TESTING ONLY

    find_master_ancestor <- SqlRead.find_master_ancestor
      connection_data
      access_token
      (DbHelpers.OwnerAndRepo Constants.project_name Constants.repo_name)
      (Builds.RawCommit "058beae4115afb76ee5f45dfa42c6ab4ee01895c")

    putStrLn $ "Master ancestor: " ++ show find_master_ancestor
  {-
    SqlWrite.populate_latest_master_commits
      connection_data
      access_token
      (DbHelpers.OwnerAndRepo Constants.project_name Constants.repo_name)
  -}
    return ()






  S.scotty prt $ scottyApp persistence_data credentials_data

  where
    credentials_data = SetupData static_base github_config connection_data
    static_base = staticBase args

    access_token = OAuth2.AccessToken $ gitHubPersonalAccessToken args
    github_config = AuthConfig.NewGithubConfig
      (runningLocally args)
      (gitHubClientID args)
      (gitHubClientSecret args)
      access_token
      (gitHubWebhookSecret args)
      (adminPassword args)

    connection_data = DbHelpers.NewDbConnectionData {
        DbHelpers.dbHostname = dbHostname args
      , DbHelpers.dbName = "loganci"
      , DbHelpers.dbUsername = "logan"
      , DbHelpers.dbPassword = dbPassword args
      }


data CommandLineArgs = NewCommandLineArgs {
    serverPort                :: Int
  , staticBase                :: String
  , dbHostname                :: String
  , dbPassword                :: String
  , gitHubClientID            :: Text
  , gitHubClientSecret        :: Text
  , gitHubPersonalAccessToken :: Text
  , gitHubWebhookSecret       :: Text
  , runningLocally            :: Bool
  , adminPassword             :: Text
  }


myCliParser :: Parser CommandLineArgs
myCliParser = NewCommandLineArgs
  <$> option auto (long "port"       <> value 3001           <> metavar "PORT"
    <> help "Webserver port")
  <*> strOption   (long "data-path" <> value "/data/static" <> metavar "STATIC_DATA"
    <> help "Path to static data files")
  <*> strOption   (long "db-hostname" <> value "localhost" <> metavar "DATABASE_HOSTNAME"
    <> help "Hostname of database")
  <*> strOption   (long "db-password" <> value "logan01" <> metavar "DATABASE_PASSWORD"
    <> help "Password for database user")
   -- Note: this is not the production password; this default is only for local testing
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


main :: IO ()
main = execParser opts >>= mainAppCode
  where
    opts = info (helper <*> myCliParser)
      ( fullDesc
     <> progDesc "CircleCI failure log analsys webserver"
     <> header "webapp - user frontend" )
