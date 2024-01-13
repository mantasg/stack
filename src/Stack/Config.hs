{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TypeFamilies          #-}

-- | The general Stack configuration that starts everything off. This should
-- be smart to fallback if there is no stack.yaml, instead relying on
-- whatever files are available.
--
-- If there is no stack.yaml, and there is a cabal.config, we
-- read in those constraints, and if there's a cabal.sandbox.config,
-- we read any constraints from there and also find the package
-- database from there, etc. And if there's nothing, we should
-- probably default to behaving like cabal, possibly with spitting out
-- a warning that "you should run `stk init` to make things better".
module Stack.Config
  ( loadConfig
  , loadConfigYaml
  , packagesParser
  , getImplicitGlobalProjectDir
  , getSnapshots
  , makeConcreteResolver
  , checkOwnership
  , getInContainer
  , getInNixShell
  , defaultConfigYaml
  , getProjectConfig
  , withBuildConfig
  , withNewLogFunc
  , determineStackRootAndOwnership
  ) where

import           Control.Monad.Extra ( firstJustM )
import           Data.Aeson.Types ( Value )
import           Data.Aeson.WarningParser
                    ( WithJSONWarnings (..), logJSONWarnings )
import           Data.Array.IArray ( (!), (//) )
import qualified Data.ByteString as S
import           Data.ByteString.Builder ( byteString )
import           Data.Coerce ( coerce )
import qualified Data.IntMap as IntMap
import qualified Data.Map as Map
import qualified Data.Map.Merge.Strict as MS
import qualified Data.Monoid
import           Data.Monoid.Map ( MonoidMap (..) )
import qualified Data.Text as T
import qualified Data.Yaml as Yaml
import           Distribution.System
                   ( Arch (..), OS (..), Platform (..), buildPlatform )
import qualified Distribution.Text ( simpleParse )
import           Distribution.Version ( simplifyVersionRange )
import           GHC.Conc ( getNumProcessors )
import           Network.HTTP.StackClient
                   ( httpJSON, parseUrlThrow, getResponseBody )
import           Options.Applicative ( Parser, help, long, metavar, strOption )
import           Path
                   ( PathException (..), (</>), parent, parseAbsDir
                   , parseAbsFile, parseRelDir, stripProperPrefix
                   )
import           Path.Extra ( toFilePathNoTrailingSep )
import           Path.Find ( findInParents )
import           Path.IO
                   ( XdgDirectory (..), canonicalizePath, doesDirExist
                   , doesFileExist, ensureDir, forgivingAbsence
                   , getAppUserDataDir, getCurrentDir, getXdgDir, resolveDir
                   , resolveDir', resolveFile'
                   )
import           RIO.List ( unzip )
import           RIO.Process
                   ( HasProcessContext (..), ProcessContext, augmentPathMap
                   , envVarsL
                   , mkProcessContext
                   )
import           RIO.Time ( toGregorian )
import           Stack.Build.Haddock ( shouldHaddockDeps )
import           Stack.Config.Build ( buildOptsFromMonoid )
import           Stack.Config.Docker ( dockerOptsFromMonoid )
import           Stack.Config.Nix ( nixOptsFromMonoid )
import           Stack.Constants
                   ( defaultGlobalConfigPath, defaultGlobalConfigPathDeprecated
                   , defaultUserConfigPath, defaultUserConfigPathDeprecated
                   , implicitGlobalProjectDir
                   , implicitGlobalProjectDirDeprecated, inContainerEnvVar
                   , inNixShellEnvVar, osIsWindows, pantryRootEnvVar
                   , platformVariantEnvVar, relDirBin, relDirStackWork
                   , relFileReadmeTxt, relFileStorage, relDirPantry
                   , relDirPrograms, relDirStackProgName, relDirUpperPrograms
                   , stackDeveloperModeDefault, stackDotYaml, stackProgName
                   , stackRootEnvVar, stackWorkEnvVar, stackXdgEnvVar
                   )
import qualified Stack.Constants as Constants
import           Stack.Lock ( lockCachedWanted )
import           Stack.Prelude
import           Stack.SourceMap
                   ( additionalDepPackage, checkFlagsUsedThrowing
                   , mkProjectPackage
                   )
import           Stack.Storage.Project ( initProjectStorage )
import           Stack.Storage.User ( initUserStorage )
import           Stack.Storage.Util ( handleMigrationException )
import           Stack.Types.AllowNewerDeps ( AllowNewerDeps (..) )
import           Stack.Types.ApplyGhcOptions ( ApplyGhcOptions (..) )
import           Stack.Types.ApplyProgOptions ( ApplyProgOptions (..) )
import           Stack.Types.Build.Exception ( BuildException (..) )
import           Stack.Types.BuildConfig ( BuildConfig (..) )
import           Stack.Types.BuildOpts ( BuildOpts (..) )
import           Stack.Types.ColorWhen ( ColorWhen (..) )
import           Stack.Types.Compiler ( defaultCompilerRepository )
import           Stack.Types.Config
                   ( Config (..), HasConfig (..), askLatestSnapshotUrl
                   , configProjectRoot, stackRootL, workDirL
                   )
import           Stack.Types.Config.Exception
                   ( ConfigException (..), ConfigPrettyException (..)
                   , ParseAbsolutePathException (..), packageIndicesWarning )
import           Stack.Types.ConfigMonoid
                   ( ConfigMonoid (..), parseConfigMonoid )
import           Stack.Types.Casa ( CasaOptsMonoid (..) )
import           Stack.Types.Docker ( DockerOptsMonoid (..), dockerEnable )
import           Stack.Types.DumpLogs ( DumpLogs (..) )
import           Stack.Types.GlobalOpts (  GlobalOpts (..) )
import           Stack.Types.Nix ( nixEnable )
import           Stack.Types.Platform
                   ( PlatformVariant (..), platformOnlyRelDir )
import           Stack.Types.Project ( Project (..) )
import           Stack.Types.ProjectAndConfigMonoid
                   ( ProjectAndConfigMonoid (..), parseProjectAndConfigMonoid )
import           Stack.Types.ProjectConfig ( ProjectConfig (..) )
import           Stack.Types.PvpBounds ( PvpBounds (..), PvpBoundsType (..) )
import           Stack.Types.Resolver ( AbstractResolver (..), Snapshots (..) )
import           Stack.Types.Runner
                   ( HasRunner (..), Runner (..), globalOptsL, terminalL )
import           Stack.Types.SourceMap
                   ( CommonPackage (..), DepPackage (..), ProjectPackage (..)
                   , SMWanted (..)
                   )
import           Stack.Types.StackYamlLoc ( StackYamlLoc (..) )
import           Stack.Types.UnusedFlags ( FlagSource (..) )
import           Stack.Types.Version
                   ( IntersectingVersionRange (..), VersionCheck (..)
                   , stackVersion, withinRange
                   )
import           System.Console.ANSI ( hSupportsANSI, setSGRCode )
import           System.Environment ( getEnvironment, lookupEnv )
import           System.Info.ShortPathName ( getShortPathName )
import           System.PosixCompat.Files ( fileOwner, getFileStatus )
import           System.Posix.User ( getEffectiveUserID )

-- | If deprecated path exists, use it and print a warning. Otherwise, return
-- the new path.
tryDeprecatedPath ::
     HasTerm env
  => Maybe T.Text
     -- ^ Description of file for warning (if Nothing, no deprecation warning is
     -- displayed)
  -> (Path Abs a -> RIO env Bool)
     -- ^ Test for existence
  -> Path Abs a
     -- ^ New path
  -> Path Abs a
     -- ^ Deprecated path
  -> RIO env (Path Abs a, Bool)
     -- ^ (Path to use, whether it already exists)
tryDeprecatedPath mWarningDesc exists new old = do
  newExists <- exists new
  if newExists
    then pure (new, True)
    else do
      oldExists <- exists old
      if oldExists
        then do
          case mWarningDesc of
            Nothing -> pure ()
            Just desc ->
              prettyWarnL
                [ flow "Location of"
                , flow (T.unpack desc)
                , "at"
                , style Dir (fromString $ toFilePath old)
                , flow "is deprecated; rename it to"
                , style Dir (fromString $ toFilePath new)
                , "instead."
                ]
          pure (old, True)
        else pure (new, False)

-- | Get the location of the implicit global project directory. If the directory
-- already exists at the deprecated location, its location is returned.
-- Otherwise, the new location is returned.
getImplicitGlobalProjectDir ::HasTerm env => Config -> RIO env (Path Abs Dir)
getImplicitGlobalProjectDir config =
  --TEST no warning printed
  fst <$> tryDeprecatedPath
    Nothing
    doesDirExist
    (implicitGlobalProjectDir stackRoot)
    (implicitGlobalProjectDirDeprecated stackRoot)
 where
  stackRoot = view stackRootL config

-- | Download the 'Snapshots' value from stackage.org.
getSnapshots :: HasConfig env => RIO env Snapshots
getSnapshots = do
  latestUrlText <- askLatestSnapshotUrl
  latestUrl <- parseUrlThrow (T.unpack latestUrlText)
  logDebug $ "Downloading snapshot versions file from " <> display latestUrlText
  result <- httpJSON latestUrl
  logDebug "Done downloading and parsing snapshot versions file"
  pure $ getResponseBody result

-- | Turn an 'AbstractResolver' into a 'Resolver'.
makeConcreteResolver ::
     HasConfig env
  => AbstractResolver
  -> RIO env RawSnapshotLocation
makeConcreteResolver (ARResolver r) = pure r
makeConcreteResolver ar = do
  r <-
    case ar of
      ARGlobal -> do
        config <- view configL
        implicitGlobalDir <- getImplicitGlobalProjectDir config
        let fp = implicitGlobalDir </> stackDotYaml
        iopc <- loadConfigYaml (parseProjectAndConfigMonoid (parent fp)) fp
        ProjectAndConfigMonoid project _ <- liftIO iopc
        pure project.projectResolver
      ARLatestNightly ->
        RSLSynonym . Nightly . (.snapshotsNightly) <$> getSnapshots
      ARLatestLTSMajor x -> do
        snapshots <- getSnapshots
        case IntMap.lookup x snapshots.snapshotsLts of
          Nothing -> throwIO $ NoLTSWithMajorVersion x
          Just y -> pure $ RSLSynonym $ LTS x y
      ARLatestLTS -> do
        snapshots <- getSnapshots
        if IntMap.null snapshots.snapshotsLts
          then throwIO NoLTSFound
          else let (x, y) = IntMap.findMax snapshots.snapshotsLts
               in  pure $ RSLSynonym $ LTS x y
  prettyInfoL
    [ flow "Selected resolver:"
    , style Current (fromString $ T.unpack $ textDisplay r) <> "."
    ]
  pure r

-- | Get the latest snapshot resolver available.
getLatestResolver :: HasConfig env => RIO env RawSnapshotLocation
getLatestResolver = do
  snapshots <- getSnapshots
  let mlts = uncurry LTS <$>
             listToMaybe (reverse (IntMap.toList snapshots.snapshotsLts))
  pure $ RSLSynonym $ fromMaybe (Nightly snapshots.snapshotsNightly) mlts

-- Interprets ConfigMonoid options.
configFromConfigMonoid ::
     (HasRunner env, HasTerm env)
  => Path Abs Dir -- ^ Stack root, e.g. ~/.stack
  -> Path Abs File -- ^ user config file path, e.g. ~/.stack/config.yaml
  -> Maybe AbstractResolver
  -> ProjectConfig (Project, Path Abs File)
  -> ConfigMonoid
  -> (Config -> RIO env a)
  -> RIO env a
configFromConfigMonoid
  stackRoot
  userConfigPath
  resolver
  project
  configMonoid
  inner
  = do
    -- If --stack-work is passed, prefer it. Otherwise, if STACK_WORK
    -- is set, use that. If neither, use the default ".stack-work"
    mstackWorkEnv <- liftIO $ lookupEnv stackWorkEnvVar
    let mproject =
          case project of
            PCProject pair -> Just pair
            PCGlobalProject -> Nothing
            PCNoProject _deps -> Nothing
        allowLocals =
          case project of
            PCProject _ -> True
            PCGlobalProject -> True
            PCNoProject _ -> False
    configWorkDir0 <-
      let parseStackWorkEnv x =
            catch
              (parseRelDir x)
              ( \e -> case e of
                  InvalidRelDir _ ->
                    prettyThrowIO $ StackWorkEnvNotRelativeDir x
                  _ -> throwIO e
              )
      in  maybe (pure relDirStackWork) (liftIO . parseStackWorkEnv) mstackWorkEnv
    let workDir = fromFirst configWorkDir0 configMonoid.configMonoidWorkDir
        latestSnapshot = fromFirst
          "https://s3.amazonaws.com/haddock.stackage.org/snapshots.json"
          configMonoid.configMonoidLatestSnapshot
        clConnectionCount = fromFirst 8 configMonoid.configMonoidConnectionCount
        hideTHLoading = fromFirstTrue configMonoid.configMonoidHideTHLoading
        prefixTimestamps = fromFirst False configMonoid.configMonoidPrefixTimestamps
        ghcVariant = getFirst configMonoid.configMonoidGHCVariant
        compilerRepository = fromFirst
          defaultCompilerRepository
          configMonoid.configMonoidCompilerRepository
        ghcBuild = getFirst configMonoid.configMonoidGHCBuild
        installGHC = fromFirstTrue configMonoid.configMonoidInstallGHC
        skipGHCCheck = fromFirstFalse configMonoid.configMonoidSkipGHCCheck
        skipMsys = fromFirstFalse configMonoid.configMonoidSkipMsys
        extraIncludeDirs = configMonoid.configMonoidExtraIncludeDirs
        extraLibDirs = configMonoid.configMonoidExtraLibDirs
        customPreprocessorExts = configMonoid.configMonoidCustomPreprocessorExts
        overrideGccPath = getFirst configMonoid.configMonoidOverrideGccPath
        -- Only place in the codebase where platform is hard-coded. In theory in
        -- the future, allow it to be configured.
        (Platform defArch defOS) = buildPlatform
        arch = fromMaybe defArch
          $ getFirst configMonoid.configMonoidArch >>= Distribution.Text.simpleParse
        os = defOS
        platform = Platform arch os
        requireStackVersion = simplifyVersionRange
          configMonoid.configMonoidRequireStackVersion.getIntersectingVersionRange
        compilerCheck = fromFirst MatchMinor configMonoid.configMonoidCompilerCheck
    platformVariant <- liftIO $
      maybe PlatformVariantNone PlatformVariant <$> lookupEnv platformVariantEnvVar
    let build = buildOptsFromMonoid configMonoid.configMonoidBuildOpts
    docker <-
      dockerOptsFromMonoid (fmap fst mproject) resolver configMonoid.configMonoidDockerOpts
    nix <- nixOptsFromMonoid configMonoid.configMonoidNixOpts os
    systemGHC <-
      case (getFirst configMonoid.configMonoidSystemGHC, nix.nixEnable) of
        (Just False, True) ->
          throwM NixRequiresSystemGhc
        _ ->
          pure
            (fromFirst
              (docker.dockerEnable || nix.nixEnable)
              configMonoid.configMonoidSystemGHC)
    when (isJust ghcVariant && systemGHC) $
      throwM ManualGHCVariantSettingsAreIncompatibleWithSystemGHC
    rawEnv <- liftIO getEnvironment
    pathsEnv <- either throwM pure
      $ augmentPathMap (map toFilePath configMonoid.configMonoidExtraPath)
                       (Map.fromList (map (T.pack *** T.pack) rawEnv))
    origEnv <- mkProcessContext pathsEnv
    let processContextSettings _ = pure origEnv
    localProgramsBase <- case getFirst configMonoid.configMonoidLocalProgramsBase of
      Nothing -> getDefaultLocalProgramsBase stackRoot platform origEnv
      Just path -> pure path
    let localProgramsFilePath = toFilePath localProgramsBase
    when (osIsWindows && ' ' `elem` localProgramsFilePath) $ do
      ensureDir localProgramsBase
      -- getShortPathName returns the long path name when a short name does not
      -- exist.
      shortLocalProgramsFilePath <-
        liftIO $ getShortPathName localProgramsFilePath
      when (' ' `elem` shortLocalProgramsFilePath) $
        prettyError $
          "[S-8432]"
          <> line
          <> fillSep
               [ flow "Stack's 'programs' path contains a space character and \
                      \has no alternative short ('8 dot 3') name. This will \
                      \cause problems with packages that use the GNU project's \
                      \'configure' shell script. Use the"
               , style Shell "local-programs-path"
               , flow "configuration option to specify an alternative path. \
                      \The current path is:"
               , style File (fromString localProgramsFilePath) <> "."
               ]
    platformOnlyDir <-
      runReaderT platformOnlyRelDir (platform, platformVariant)
    let localPrograms = localProgramsBase </> platformOnlyDir
    localBin <-
      case getFirst configMonoid.configMonoidLocalBinPath of
        Nothing -> do
          localDir <- getAppUserDataDir "local"
          pure $ localDir </> relDirBin
        Just userPath ->
          (case mproject of
            -- Not in a project
            Nothing -> resolveDir' userPath
            -- Resolves to the project dir and appends the user path if it is
            -- relative
            Just (_, configYaml) -> resolveDir (parent configYaml) userPath)
          -- TODO: Either catch specific exceptions or add a
          -- parseRelAsAbsDirMaybe utility and use it along with
          -- resolveDirMaybe.
          `catchAny`
          const (throwIO (NoSuchDirectory userPath))
    jobs <-
      case getFirst configMonoid.configMonoidJobs of
        Nothing -> liftIO getNumProcessors
        Just i -> pure i
    let concurrentTests =
          fromFirst True configMonoid.configMonoidConcurrentTests
        templateParams = configMonoid.configMonoidTemplateParameters
        scmInit = getFirst configMonoid.configMonoidScmInit
        cabalConfigOpts = coerce configMonoid.configMonoidCabalConfigOpts
        ghcOptionsByName = coerce configMonoid.configMonoidGhcOptionsByName
        ghcOptionsByCat = coerce configMonoid.configMonoidGhcOptionsByCat
        setupInfoLocations = configMonoid.configMonoidSetupInfoLocations
        setupInfoInline = configMonoid.configMonoidSetupInfoInline
        pvpBounds =
          fromFirst (PvpBounds PvpBoundsNone False) configMonoid.configMonoidPvpBounds
        modifyCodePage = fromFirstTrue configMonoid.configMonoidModifyCodePage
        rebuildGhcOptions =
          fromFirstFalse configMonoid.configMonoidRebuildGhcOptions
        applyGhcOptions =
          fromFirst AGOLocals configMonoid.configMonoidApplyGhcOptions
        applyProgOptions =
          fromFirst APOLocals configMonoid.configMonoidApplyProgOptions
        allowNewer = fromFirst False configMonoid.configMonoidAllowNewer
        allowNewerDeps = coerce configMonoid.configMonoidAllowNewerDeps
        defaultTemplate = getFirst configMonoid.configMonoidDefaultTemplate
        dumpLogs = fromFirst DumpWarningLogs configMonoid.configMonoidDumpLogs
        saveHackageCreds =
          fromFirst True configMonoid.configMonoidSaveHackageCreds
        hackageBaseUrl =
          fromFirst Constants.hackageBaseUrl configMonoid.configMonoidHackageBaseUrl
        hideSourcePaths = fromFirstTrue configMonoid.configMonoidHideSourcePaths
        recommendUpgrade = fromFirstTrue configMonoid.configMonoidRecommendUpgrade
        notifyIfNixOnPath = fromFirstTrue configMonoid.configMonoidNotifyIfNixOnPath
        notifyIfGhcUntested = fromFirstTrue configMonoid.configMonoidNotifyIfGhcUntested
        notifyIfCabalUntested = fromFirstTrue configMonoid.configMonoidNotifyIfCabalUntested
        notifyIfArchUnknown = fromFirstTrue configMonoid.configMonoidNotifyIfArchUnknown
        noRunCompile = fromFirstFalse configMonoid.configMonoidNoRunCompile
    allowDifferentUser <-
      case getFirst configMonoid.configMonoidAllowDifferentUser of
        Just True -> pure True
        _ -> getInContainer
    configRunner' <- view runnerL
    useAnsi <- liftIO $ hSupportsANSI stderr
    let stylesUpdate' = (configRunner' ^. stylesUpdateL) <>
          configMonoid.configMonoidStyles
        useColor' = configRunner'.runnerUseColor
        mUseColor = do
          colorWhen <- getFirst configMonoid.configMonoidColorWhen
          pure $ case colorWhen of
            ColorNever  -> False
            ColorAlways -> True
            ColorAuto  -> useAnsi
        useColor'' = fromMaybe useColor' mUseColor
        configRunner'' = configRunner'
          & processContextL .~ origEnv
          & stylesUpdateL .~ stylesUpdate'
          & useColorL .~ useColor''
        go = configRunner'.runnerGlobalOpts
    pic <-
      case getFirst configMonoid.configMonoidPackageIndex of
        Nothing ->
          case getFirst configMonoid.configMonoidPackageIndices of
            Nothing -> pure defaultPackageIndexConfig
            Just [pic] -> do
              prettyWarn packageIndicesWarning
              pure pic
            Just x -> prettyThrowIO $ MultiplePackageIndices x
        Just pic -> pure pic
    mpantryRoot <- liftIO $ lookupEnv pantryRootEnvVar
    pantryRoot <-
      case mpantryRoot of
        Just dir ->
          case parseAbsDir dir of
            Nothing -> throwIO $ ParseAbsolutePathException pantryRootEnvVar dir
            Just x -> pure x
        Nothing -> pure $ stackRoot </> relDirPantry
    let snapLoc =
          case getFirst configMonoid.configMonoidSnapshotLocation of
            Nothing -> defaultSnapshotLocation
            Just addr ->
              customSnapshotLocation
               where
                customSnapshotLocation (LTS x y) =
                  mkRSLUrl $ addr'
                    <> "/lts/" <> display x
                    <> "/" <> display y <> ".yaml"
                customSnapshotLocation (Nightly date) =
                  let (year, month, day) = toGregorian date
                  in  mkRSLUrl $ addr'
                        <> "/nightly/"
                        <> display year
                        <> "/" <> display month
                        <> "/" <> display day <> ".yaml"
                mkRSLUrl builder = RSLUrl (utf8BuilderToText builder) Nothing
                addr' = display $ T.dropWhileEnd (=='/') addr
    let stackDeveloperMode = fromFirst
          stackDeveloperModeDefault
          configMonoid.configMonoidStackDeveloperMode
        casa =
          if fromFirstTrue configMonoid.configMonoidCasaOpts.casaMonoidEnable
            then
              let casaRepoPrefix = fromFirst
                    (fromFirst defaultCasaRepoPrefix configMonoid.configMonoidCasaRepoPrefix)
                    configMonoid.configMonoidCasaOpts.casaMonoidRepoPrefix
                  casaMaxKeysPerRequest = fromFirst
                    defaultCasaMaxPerRequest
                    configMonoid.configMonoidCasaOpts.casaMonoidMaxKeysPerRequest
              in  Just (casaRepoPrefix, casaMaxKeysPerRequest)
            else Nothing
    withNewLogFunc go useColor'' stylesUpdate' $ \logFunc -> do
      let runner = configRunner'' & logFuncL .~ logFunc
      withLocalLogFunc logFunc $ handleMigrationException $ do
        logDebug $ case casa of
          Nothing -> "Use of Casa server disabled."
          Just (repoPrefix, maxKeys) ->
               "Use of Casa server enabled: ("
            <> fromString (show repoPrefix)
            <> ", "
            <> fromString (show maxKeys)
            <> ")."
        withPantryConfig'
          pantryRoot
          pic
          (maybe HpackBundled HpackCommand $ getFirst configMonoid.configMonoidOverrideHpack)
          clConnectionCount
          casa
          snapLoc
          (\pantryConfig -> initUserStorage
            (stackRoot </> relFileStorage)
            ( \userStorage -> inner Config
                { workDir
                , userConfigPath
                , build
                , docker
                , nix
                , processContextSettings
                , localProgramsBase
                , localPrograms
                , hideTHLoading
                , prefixTimestamps
                , platform
                , platformVariant
                , ghcVariant
                , ghcBuild
                , latestSnapshot
                , systemGHC
                , installGHC
                , skipGHCCheck
                , skipMsys
                , compilerCheck
                , compilerRepository
                , localBin
                , requireStackVersion
                , jobs
                , overrideGccPath
                , extraIncludeDirs
                , extraLibDirs
                , customPreprocessorExts
                , concurrentTests
                , templateParams
                , scmInit
                , ghcOptionsByName
                , ghcOptionsByCat
                , cabalConfigOpts
                , setupInfoLocations
                , setupInfoInline
                , pvpBounds
                , modifyCodePage
                , rebuildGhcOptions
                , applyGhcOptions
                , applyProgOptions
                , allowNewer
                , allowNewerDeps
                , defaultTemplate
                , allowDifferentUser
                , dumpLogs
                , project
                , allowLocals
                , saveHackageCreds
                , hackageBaseUrl
                , runner
                , pantryConfig
                , stackRoot
                , resolver
                , userStorage
                , hideSourcePaths
                , recommendUpgrade
                , notifyIfNixOnPath
                , notifyIfGhcUntested
                , notifyIfCabalUntested
                , notifyIfArchUnknown
                , noRunCompile
                , stackDeveloperMode
                , casa
                }
            )
          )

-- | Runs the provided action with the given 'LogFunc' in the environment
withLocalLogFunc :: HasLogFunc env => LogFunc -> RIO env a -> RIO env a
withLocalLogFunc logFunc = local (set logFuncL logFunc)

-- | Runs the provided action with a new 'LogFunc', given a 'StylesUpdate'.
withNewLogFunc :: MonadUnliftIO m
               => GlobalOpts
               -> Bool  -- ^ Use color
               -> StylesUpdate
               -> (LogFunc -> m a)
               -> m a
withNewLogFunc go useColor (StylesUpdate update) inner = do
  logOptions0 <- logOptionsHandle stderr False
  let logOptions
        = setLogUseColor useColor
        $ setLogLevelColors logLevelColors
        $ setLogSecondaryColor secondaryColor
        $ setLogAccentColors (const highlightColor)
        $ setLogUseTime go.globalTimeInLog
        $ setLogMinLevel go.globalLogLevel
        $ setLogVerboseFormat (go.globalLogLevel <= LevelDebug)
        $ setLogTerminal go.globalTerminal
          logOptions0
  withLogFunc logOptions inner
 where
  styles = defaultStyles // update
  logLevelColors :: LogLevel -> Utf8Builder
  logLevelColors level =
    fromString $ setSGRCode $ snd $ styles ! logLevelToStyle level
  secondaryColor = fromString $ setSGRCode $ snd $ styles ! Secondary
  highlightColor = fromString $ setSGRCode $ snd $ styles ! Highlight

-- | Get the default location of the local programs directory.
getDefaultLocalProgramsBase :: MonadThrow m
                            => Path Abs Dir
                            -> Platform
                            -> ProcessContext
                            -> m (Path Abs Dir)
getDefaultLocalProgramsBase configStackRoot configPlatform override =
  case configPlatform of
    -- For historical reasons, on Windows a subdirectory of LOCALAPPDATA is
    -- used instead of a subdirectory of STACK_ROOT. Unifying the defaults would
    -- mean that Windows users would manually have to move data from the old
    -- location to the new one, which is undesirable.
    Platform _ Windows -> do
      let envVars = view envVarsL override
      case T.unpack <$> Map.lookup "LOCALAPPDATA" envVars of
        Just t -> case parseAbsDir t of
          Nothing ->
            throwM $ ParseAbsolutePathException "LOCALAPPDATA" t
          Just lad ->
            pure $ lad </> relDirUpperPrograms </> relDirStackProgName
        Nothing -> pure defaultBase
    _ -> pure defaultBase
 where
  defaultBase = configStackRoot </> relDirPrograms

-- | Load the configuration, using current directory, environment variables,
-- and defaults as necessary.
loadConfig ::
     (HasRunner env, HasTerm env)
  => (Config -> RIO env a)
  -> RIO env a
loadConfig inner = do
  mstackYaml <- view $ globalOptsL . to (.globalStackYaml)
  mproject <- loadProjectConfig mstackYaml
  mresolver <- view $ globalOptsL . to (.globalResolver)
  configArgs <- view $ globalOptsL . to (.globalConfigMonoid)
  (configRoot, stackRoot, userOwnsStackRoot) <-
    determineStackRootAndOwnership configArgs

  let (mproject', addConfigMonoid) =
        case mproject of
          PCProject (proj, fp, cm) -> (PCProject (proj, fp), (cm:))
          PCGlobalProject -> (PCGlobalProject, id)
          PCNoProject deps -> (PCNoProject deps, id)

  userConfigPath <- getDefaultUserConfigPath configRoot
  extraConfigs0 <- getExtraConfigs userConfigPath >>=
    mapM (\file -> loadConfigYaml (parseConfigMonoid (parent file)) file)
  let extraConfigs =
        -- non-project config files' existence of a docker section should never
        -- default docker to enabled, so make it look like they didn't exist
        map
          ( \c -> c {configMonoidDockerOpts =
              c.configMonoidDockerOpts {dockerMonoidDefaultEnable = Any False}}
          )
          extraConfigs0

  let withConfig =
        configFromConfigMonoid
          stackRoot
          userConfigPath
          mresolver
          mproject'
          (mconcat $ configArgs : addConfigMonoid extraConfigs)

  withConfig $ \config -> do
    let Platform arch _ = config.platform
    case arch of
      OtherArch unknownArch
        | config.notifyIfArchUnknown ->
            prettyWarnL
              [ flow "Unknown value for architecture setting:"
              , style Shell (fromString unknownArch) <> "."
              , flow "To mute this message in future, set"
              , style Shell (flow "notify-if-arch-unknown: false")
              , flow "in Stack's configuration."
              ]
      _ -> pure ()
    unless (stackVersion `withinRange` config.requireStackVersion)
      (throwM (BadStackVersionException config.requireStackVersion))
    unless config.allowDifferentUser $ do
      unless userOwnsStackRoot $
        throwM (UserDoesn'tOwnDirectory stackRoot)
      forM_ (configProjectRoot config) $ \dir ->
        checkOwnership (dir </> config.workDir)
    inner config

-- | Load the build configuration, adds build-specific values to config loaded
-- by @loadConfig@. values.
withBuildConfig :: RIO BuildConfig a -> RIO Config a
withBuildConfig inner = do
  config <- ask

  -- If provided, turn the AbstractResolver from the command line into a
  -- Resolver that can be used below.

  -- The configResolver and mcompiler are provided on the command line. In order
  -- to properly deal with an AbstractResolver, we need a base directory (to
  -- deal with custom snapshot relative paths). We consider the current working
  -- directory to be the correct base. Let's calculate the mresolver first.
  mresolver <- forM config.resolver $ \aresolver -> do
    logDebug ("Using resolver: " <> display aresolver <> " specified on command line")
    makeConcreteResolver aresolver

  (project', stackYamlFP) <- case config.project of
    PCProject (project, fp) -> do
      forM_ project.projectUserMsg prettyWarnS
      pure (project, fp)
    PCNoProject extraDeps -> do
      p <-
        case mresolver of
          Nothing -> throwIO NoResolverWhenUsingNoProject
          Just _ -> getEmptyProject mresolver extraDeps
      pure (p, config.userConfigPath)
    PCGlobalProject -> do
      logDebug "Run from outside a project, using implicit global project config"
      destDir <- getImplicitGlobalProjectDir config
      let dest :: Path Abs File
          dest = destDir </> stackDotYaml
          dest' :: FilePath
          dest' = toFilePath dest
      ensureDir destDir
      exists <- doesFileExist dest
      if exists
        then do
          iopc <- loadConfigYaml (parseProjectAndConfigMonoid destDir) dest
          ProjectAndConfigMonoid project _ <- liftIO iopc
          when (view terminalL config) $
            case config.resolver of
              Nothing ->
                logDebug $
                     "Using resolver: "
                  <> display project.projectResolver
                  <> " from implicit global project's config file: "
                  <> fromString dest'
              Just _ -> pure ()
          pure (project, dest)
        else do
          prettyInfoL
            [ flow "Writing the configuration file for the implicit \
                   \global project to:"
            , pretty dest <> "."
            , flow "Note: You can change the snapshot via the"
            , style Shell "resolver"
            , flow "field there."
            ]
          p <- getEmptyProject mresolver []
          liftIO $ do
            writeBinaryFileAtomic dest $ byteString $ S.concat
              [ "# This is the implicit global project's config file, which is only used when\n"
              , "# 'stack' is run outside of a real project. Settings here do _not_ act as\n"
              , "# defaults for all projects. To change Stack's default settings, edit\n"
              , "# '", encodeUtf8 (T.pack $ toFilePath config.userConfigPath), "' instead.\n"
              , "#\n"
              , "# For more information about Stack's configuration, see\n"
              , "# http://docs.haskellstack.org/en/stable/yaml_configuration/\n"
              , "#\n"
              , Yaml.encode p]
            writeBinaryFileAtomic (parent dest </> relFileReadmeTxt) $
              "This is the implicit global project, which is " <>
              "used only when 'stack' is run\noutside of a " <>
              "real project.\n"
          pure (p, dest)
  mcompiler <- view $ globalOptsL . to (.globalCompiler)
  let project = project'
        { projectCompiler = mcompiler <|> project'.projectCompiler
        , projectResolver = fromMaybe project'.projectResolver mresolver
        }
  extraPackageDBs <- mapM resolveDir' project.projectExtraPackageDBs

  wanted <- lockCachedWanted stackYamlFP project.projectResolver $
    fillProjectWanted stackYamlFP config project

  -- Unfortunately redoes getProjectWorkDir, since we don't have a BuildConfig
  -- yet
  workDir <- view workDirL
  let projectStorageFile = parent stackYamlFP </> workDir </> relFileStorage

  initProjectStorage projectStorageFile $ \projectStorage -> do
    let bc = BuildConfig
          { bcConfig = config
          , bcSMWanted = wanted
          , bcExtraPackageDBs = extraPackageDBs
          , bcStackYaml = stackYamlFP
          , bcCurator = project.projectCurator
          , bcProjectStorage = projectStorage
          }
    runRIO bc inner
 where
  getEmptyProject ::
       Maybe RawSnapshotLocation
    -> [PackageIdentifierRevision]
    -> RIO Config Project
  getEmptyProject mresolver extraDeps = do
    r <- case mresolver of
      Just resolver -> do
        prettyInfoL
          [ flow "Using the snapshot"
          , style Current (fromString $ T.unpack $ textDisplay resolver)
          , flow "specified on the command line."
          ]
        pure resolver
      Nothing -> do
        r'' <- getLatestResolver
        prettyInfoL
          [ flow "Using the latest snapshot"
          , style Current (fromString $ T.unpack $ textDisplay r'') <> "."
          ]
        pure r''
    pure Project
      { projectUserMsg = Nothing
      , projectPackages = []
      , projectDependencies =
          map (RPLImmutable . flip RPLIHackage Nothing) extraDeps
      , projectFlags = mempty
      , projectResolver = r
      , projectCompiler = Nothing
      , projectExtraPackageDBs = []
      , projectCurator = Nothing
      , projectDropPackages = mempty
      }

fillProjectWanted ::
     (HasLogFunc env, HasPantryConfig env, HasProcessContext env)
  => Path Abs t
  -> Config
  -> Project
  -> Map RawPackageLocationImmutable PackageLocationImmutable
  -> WantedCompiler
  -> Map PackageName (Bool -> RIO env DepPackage)
  -> RIO env (SMWanted, [CompletedPLI])
fillProjectWanted stackYamlFP config project locCache snapCompiler snapPackages = do
  let bopts = config.build

  packages0 <- for project.projectPackages $ \fp@(RelFilePath t) -> do
    abs' <- resolveDir (parent stackYamlFP) (T.unpack t)
    let resolved = ResolvedPath fp abs'
    pp <- mkProjectPackage YesPrintWarnings resolved bopts.boptsHaddock
    pure (pp.ppCommon.cpName, pp)

  -- prefetch git repos to avoid cloning per subdirectory
  -- see https://github.com/commercialhaskell/stack/issues/5411
  let gitRepos = mapMaybe
        ( \case
            (RPLImmutable (RPLIRepo repo rpm)) -> Just (repo, rpm)
            _ -> Nothing
        )
        project.projectDependencies
  logDebug ("Prefetching git repos: " <> display (T.pack (show gitRepos)))
  fetchReposRaw gitRepos

  (deps0, mcompleted) <- fmap unzip . forM project.projectDependencies $ \rpl -> do
    (pl, mCompleted) <- case rpl of
       RPLImmutable rpli -> do
         (compl, mcompl) <-
           case Map.lookup rpli locCache of
             Just compl -> pure (compl, Just compl)
             Nothing -> do
               cpl <- completePackageLocation rpli
               if cplHasCabalFile cpl
                 then pure (cplComplete cpl, Just $ cplComplete cpl)
                 else do
                   warnMissingCabalFile rpli
                   pure (cplComplete cpl, Nothing)
         pure (PLImmutable compl, CompletedPLI rpli <$> mcompl)
       RPLMutable p ->
         pure (PLMutable p, Nothing)
    dp <- additionalDepPackage (shouldHaddockDeps bopts) pl
    pure ((dp.dpCommon.cpName, dp), mCompleted)

  checkDuplicateNames $
    map (second (PLMutable . (.ppResolvedDir))) packages0 ++
    map (second (.dpLocation)) deps0

  let packages1 = Map.fromList packages0
      snPackages = snapPackages
        `Map.difference` packages1
        `Map.difference` Map.fromList deps0
        `Map.withoutKeys` project.projectDropPackages

  snDeps <- for snPackages $ \getDep -> getDep (shouldHaddockDeps bopts)

  let deps1 = Map.fromList deps0 `Map.union` snDeps

  let mergeApply m1 m2 f =
        MS.merge MS.preserveMissing MS.dropMissing (MS.zipWithMatched f) m1 m2
      pFlags = project.projectFlags
      packages2 = mergeApply packages1 pFlags $
        \_ p flags -> p{ppCommon = p.ppCommon {cpFlags=flags}}
      deps2 = mergeApply deps1 pFlags $
        \_ d flags -> d{dpCommon = d.dpCommon {cpFlags=flags}}

  checkFlagsUsedThrowing pFlags FSStackYaml packages1 deps1

  let pkgGhcOptions = config.ghcOptionsByName
      deps = mergeApply deps2 pkgGhcOptions $
        \_ d options -> d{dpCommon = d.dpCommon {cpGhcOptions=options}}
      packages = mergeApply packages2 pkgGhcOptions $
        \_ p options -> p{ppCommon = p.ppCommon {cpGhcOptions=options}}
      unusedPkgGhcOptions =
        pkgGhcOptions `Map.restrictKeys` Map.keysSet packages2
          `Map.restrictKeys` Map.keysSet deps2

  unless (Map.null unusedPkgGhcOptions) $
    throwM $ InvalidGhcOptionsSpecification (Map.keys unusedPkgGhcOptions)

  let wanted = SMWanted
        { smwCompiler = fromMaybe snapCompiler project.projectCompiler
        , smwProject = packages
        , smwDeps = deps
        , smwSnapshotLocation = project.projectResolver
        }

  pure (wanted, catMaybes mcompleted)


-- | Check if there are any duplicate package names and, if so, throw an
-- exception.
checkDuplicateNames :: MonadThrow m => [(PackageName, PackageLocation)] -> m ()
checkDuplicateNames locals =
  case filter hasMultiples $ Map.toList $ Map.fromListWith (++) $ map (second pure) locals of
    [] -> pure ()
    x -> prettyThrowM $ DuplicateLocalPackageNames x
 where
  hasMultiples (_, _:_:_) = True
  hasMultiples _ = False


-- | Get the Stack root, e.g. @~/.stack@, and determine whether the user owns it.
--
-- On Windows, the second value is always 'True'.
determineStackRootAndOwnership ::
     MonadIO m
  => ConfigMonoid
  -- ^ Parsed command-line arguments
  -> m (Path Abs Dir, Path Abs Dir, Bool)
determineStackRootAndOwnership clArgs = liftIO $ do
  (configRoot, stackRoot) <- do
    case getFirst clArgs.configMonoidStackRoot of
      Just x -> pure (x, x)
      Nothing -> do
        mstackRoot <- lookupEnv stackRootEnvVar
        case mstackRoot of
          Nothing -> do
            wantXdg <- fromMaybe "" <$> lookupEnv stackXdgEnvVar
            if not (null wantXdg)
              then do
                xdgRelDir <- parseRelDir stackProgName
                (,)
                  <$> getXdgDir XdgConfig (Just xdgRelDir)
                  <*> getXdgDir XdgData (Just xdgRelDir)
              else do
                oldStyleRoot <- getAppUserDataDir stackProgName
                pure (oldStyleRoot, oldStyleRoot)
          Just x -> case parseAbsDir x of
            Nothing ->
              throwIO $ ParseAbsolutePathException stackRootEnvVar x
            Just parsed -> pure (parsed, parsed)

  (existingStackRootOrParentDir, userOwnsIt) <- do
    mdirAndOwnership <- findInParents getDirAndOwnership stackRoot
    case mdirAndOwnership of
      Just x -> pure x
      Nothing -> throwIO (BadStackRoot stackRoot)

  when (existingStackRootOrParentDir /= stackRoot) $
    if userOwnsIt
      then ensureDir stackRoot
      else throwIO $
        Won'tCreateStackRootInDirectoryOwnedByDifferentUser
          stackRoot
          existingStackRootOrParentDir

  configRoot' <- canonicalizePath configRoot
  stackRoot' <- canonicalizePath stackRoot
  pure (configRoot', stackRoot', userOwnsIt)

-- | @'checkOwnership' dir@ throws 'UserDoesn'tOwnDirectory' if @dir@ isn't
-- owned by the current user.
--
-- If @dir@ doesn't exist, its parent directory is checked instead.
-- If the parent directory doesn't exist either,
-- @'NoSuchDirectory' ('parent' dir)@ is thrown.
checkOwnership :: MonadIO m => Path Abs Dir -> m ()
checkOwnership dir = do
  mdirAndOwnership <- firstJustM getDirAndOwnership [dir, parent dir]
  case mdirAndOwnership of
    Just (_, True) -> pure ()
    Just (dir', False) -> throwIO (UserDoesn'tOwnDirectory dir')
    Nothing ->
      throwIO . NoSuchDirectory $ (toFilePathNoTrailingSep . parent) dir

-- | @'getDirAndOwnership' dir@ returns @'Just' (dir, 'True')@ when @dir@
-- exists and the current user owns it in the sense of 'isOwnedByUser'.
getDirAndOwnership ::
     MonadIO m
  => Path Abs Dir
  -> m (Maybe (Path Abs Dir, Bool))
getDirAndOwnership dir = liftIO $ forgivingAbsence $ do
    ownership <- isOwnedByUser dir
    pure (dir, ownership)

-- | Check whether the current user (determined with 'getEffectiveUserId') is
-- the owner for the given path.
--
-- Will always pure 'True' on Windows.
isOwnedByUser :: MonadIO m => Path Abs t -> m Bool
isOwnedByUser path = liftIO $
  if osIsWindows
    then pure True
    else do
      fileStatus <- getFileStatus (toFilePath path)
      user <- getEffectiveUserID
      pure (user == fileOwner fileStatus)

-- | 'True' if we are currently running inside a Docker container.
getInContainer :: MonadIO m => m Bool
getInContainer = liftIO (isJust <$> lookupEnv inContainerEnvVar)

-- | 'True' if we are currently running inside a Nix.
getInNixShell :: MonadIO m => m Bool
getInNixShell = liftIO (isJust <$> lookupEnv inNixShellEnvVar)

-- | Determine the extra config file locations which exist.
--
-- Returns most local first
getExtraConfigs :: HasTerm env
                => Path Abs File -- ^ use config path
                -> RIO env [Path Abs File]
getExtraConfigs userConfigPath = do
  defaultStackGlobalConfigPath <- getDefaultGlobalConfigPath
  liftIO $ do
    env <- getEnvironment
    mstackConfig <-
        maybe (pure Nothing) (fmap Just . parseAbsFile)
      $ lookup "STACK_CONFIG" env
    mstackGlobalConfig <-
        maybe (pure Nothing) (fmap Just . parseAbsFile)
      $ lookup "STACK_GLOBAL_CONFIG" env
    filterM doesFileExist
        $ fromMaybe userConfigPath mstackConfig
        : maybe [] pure (mstackGlobalConfig <|> defaultStackGlobalConfigPath)

-- | Load and parse YAML from the given config file. Throws
-- 'ParseConfigFileException' when there's a decoding error.
loadConfigYaml ::
     HasLogFunc env
  => (Value -> Yaml.Parser (WithJSONWarnings a))
  -> Path Abs File -> RIO env a
loadConfigYaml parser path = do
  eres <- loadYaml parser path
  case eres of
    Left err -> prettyThrowM (ParseConfigFileException path err)
    Right res -> pure res

-- | Load and parse YAML from the given file.
loadYaml ::
     HasLogFunc env
  => (Value -> Yaml.Parser (WithJSONWarnings a))
  -> Path Abs File
  -> RIO env (Either Yaml.ParseException a)
loadYaml parser path = do
  eres <- liftIO $ Yaml.decodeFileEither (toFilePath path)
  case eres  of
    Left err -> pure (Left err)
    Right val ->
      case Yaml.parseEither parser val of
        Left err -> pure (Left (Yaml.AesonException err))
        Right (WithJSONWarnings res warnings) -> do
          logJSONWarnings (toFilePath path) warnings
          pure (Right res)

-- | Get the location of the project config file, if it exists.
getProjectConfig :: HasTerm env
                 => StackYamlLoc
                 -- ^ Override stack.yaml
                 -> RIO env (ProjectConfig (Path Abs File))
getProjectConfig (SYLOverride stackYaml) = pure $ PCProject stackYaml
getProjectConfig SYLGlobalProject = pure PCGlobalProject
getProjectConfig SYLDefault = do
  env <- liftIO getEnvironment
  case lookup "STACK_YAML" env of
    Just fp -> do
      prettyInfoS
        "Getting the project-level configuration file from the \
        \STACK_YAML environment variable."
      PCProject <$> resolveFile' fp
    Nothing -> do
      currDir <- getCurrentDir
      maybe PCGlobalProject PCProject <$> findInParents getStackDotYaml currDir
 where
  getStackDotYaml dir = do
    let fp = dir </> stackDotYaml
        fp' = toFilePath fp
    logDebug $ "Checking for project config at: " <> fromString fp'
    exists <- doesFileExist fp
    if exists
      then pure $ Just fp
      else pure Nothing
getProjectConfig (SYLNoProject extraDeps) = pure $ PCNoProject extraDeps

-- | Find the project config file location, respecting environment variables
-- and otherwise traversing parents. If no config is found, we supply a default
-- based on current directory.
loadProjectConfig ::
     HasTerm env
  => StackYamlLoc
     -- ^ Override stack.yaml
  -> RIO env (ProjectConfig (Project, Path Abs File, ConfigMonoid))
loadProjectConfig mstackYaml = do
  mfp <- getProjectConfig mstackYaml
  case mfp of
    PCProject fp -> do
      currDir <- getCurrentDir
      logDebug $ "Loading project config file " <>
                  fromString (maybe (toFilePath fp) toFilePath (stripProperPrefix currDir fp))
      PCProject <$> load fp
    PCGlobalProject -> do
      logDebug "No project config file found, using defaults."
      pure PCGlobalProject
    PCNoProject extraDeps -> do
      logDebug "Ignoring config files"
      pure $ PCNoProject extraDeps
 where
  load fp = do
    iopc <- loadConfigYaml (parseProjectAndConfigMonoid (parent fp)) fp
    ProjectAndConfigMonoid project config <- liftIO iopc
    pure (project, fp, config)

-- | Get the location of the default Stack configuration file. If a file already
-- exists at the deprecated location, its location is returned. Otherwise, the
-- new location is returned.
getDefaultGlobalConfigPath ::
     HasTerm env
  => RIO env (Maybe (Path Abs File))
getDefaultGlobalConfigPath =
  case (defaultGlobalConfigPath, defaultGlobalConfigPathDeprecated) of
    (Just new, Just old) ->
      Just . fst <$>
        tryDeprecatedPath
          (Just "non-project global configuration file")
          doesFileExist
          new
          old
    (Just new,Nothing) -> pure (Just new)
    _ -> pure Nothing

-- | Get the location of the default user configuration file. If a file already
-- exists at the deprecated location, its location is returned. Otherwise, the
-- new location is returned.
getDefaultUserConfigPath ::
     HasTerm env
  => Path Abs Dir
  -> RIO env (Path Abs File)
getDefaultUserConfigPath stackRoot = do
  (path, exists) <- tryDeprecatedPath
    (Just "non-project configuration file")
    doesFileExist
    (defaultUserConfigPath stackRoot)
    (defaultUserConfigPathDeprecated stackRoot)
  unless exists $ do
    ensureDir (parent path)
    liftIO $ writeBinaryFileAtomic path defaultConfigYaml
  pure path

packagesParser :: Parser [String]
packagesParser = many (strOption
                   (long "package" <>
                     metavar "PACKAGE" <>
                     help "Add a package (can be specified multiple times)"))

defaultConfigYaml :: (IsString s, Semigroup s) => s
defaultConfigYaml =
  "# This file contains default non-project-specific settings for Stack, used\n" <>
  "# in all projects. For more information about Stack's configuration, see\n" <>
  "# http://docs.haskellstack.org/en/stable/yaml_configuration/\n" <>
  "\n" <>
  "# The following parameters are used by 'stack new' to automatically fill fields\n" <>
  "# in the Cabal file. We recommend uncommenting them and filling them out if\n" <>
  "# you intend to use 'stack new'.\n" <>
  "# See https://docs.haskellstack.org/en/stable/yaml_configuration/#templates\n" <>
  "templates:\n" <>
  "  params:\n" <>
  "#    author-name:\n" <>
  "#    author-email:\n" <>
  "#    copyright:\n" <>
  "#    github-username:\n" <>
  "\n" <>
  "# The following parameter specifies Stack's output styles; STYLES is a\n" <>
  "# colon-delimited sequence of key=value, where 'key' is a style name and\n" <>
  "# 'value' is a semicolon-delimited list of 'ANSI' SGR (Select Graphic\n" <>
  "# Rendition) control codes (in decimal). Use 'stack ls stack-colors --basic'\n" <>
  "# to see the current sequence.\n" <>
  "# stack-colors: STYLES\n"
