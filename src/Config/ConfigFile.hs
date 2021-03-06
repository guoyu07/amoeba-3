-- | Read configuration settings from a configuration file.
--
--   The potential locations of these files are hardcoded here,
--   in the (non-exposed) '@configFiles@ value.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_HADDOCK show-extensions #-}

module Config.ConfigFile (
        nodeModifier
      , bootstrapModifier
      , drawingModifier
      , multiModifier
) where

import Data.Char (toLower)
import Data.Monoid
import Data.Functor
import Control.Monad.Reader
import qualified Data.Set as Set

import qualified Data.Configurator as C
import qualified Data.Configurator.Types as C
import qualified Data.Text as Text
import qualified Data.Traversable as T

import Control.Lens hiding (to)
import qualified Types.Lens as L

import qualified Types as Ty
import Config.OptionModifier
import qualified Config.AddressParser as AP


-- | Files to read the config from. The later in the list, the higher the
--   precedence of the contained settings.
configFiles :: [C.Worth FilePath]
configFiles = [ C.Optional "$(HOME)/.local/share/amoeba/amoeba.cfg"
              , C.Optional "$(HOME)/.amoeba.cfg"
              , C.Optional "amoeba.cfg"
              ]



-- | Get the node option modifier from the top level of the configuration file
nodeModifier :: IO (OptionModifier Ty.NodeConfig)
nodeModifier = C.load configFiles >>= runReaderT (nodeModifier' [])

-- | Get the bootstrap option modifier by first reading the top level of the
--   configuration file, and then overwriting the values obtained by what is
--   found under the \"bootstrap\" prefix.
bootstrapModifier :: IO (OptionModifier Ty.BootstrapConfig)
bootstrapModifier = C.load configFiles >>= runReaderT bootstrapModifier'

-- | Get the drawing option modifier by first reading the top level of the
--   configuration file, and then overwriting the values obtained by what is
--   found under the \"drawing\" prefix.
drawingModifier :: IO (OptionModifier Ty.DrawingConfig)
drawingModifier = C.load configFiles >>= runReaderT drawingModifier'

-- | Get the multi option modifier by first reading the top level of the
--   configuration file, and then overwriting the values obtained by what is
--   found under the \"multi\" prefix.
multiModifier :: IO (OptionModifier Ty.MultiConfig)
multiModifier = C.load configFiles >>= runReaderT multiModifier'





-- | Get the pool node modifier given a certain "Prefix".
nodeModifier' :: Prefixes -> ReaderT C.Config IO (OptionModifier Ty.NodeConfig)
nodeModifier' prefixes = (fmap mconcat . T.sequenceA) mods where
      mods = map ($ prefixes)
                  [ serverPort
                  , minNeighbours
                  , maxNeighbours
                  , maxChanSize
                  , hardBounces
                  , acceptP
                  , maxSoftBounces
                  , shortTickRate
                  , mediumTickRate
                  , longTickRate
                  , poolTimeout
                  , verbosity
                  , bootstrapServers
                  , floodMessageCache
                  ]



-- | Get the pool modifier given a certain "Prefix".
poolModifier' :: Prefixes -> ReaderT C.Config IO (OptionModifier Ty.PoolConfig)
poolModifier' prefixes = (fmap mconcat . T.sequenceA) mods where
      mods = map ($ prefixes) [ poolSize ]



noPrefix :: [a]
noPrefix = []



-- | Read the general config, before overwriting it with values with the
--   @bootstrap@ prefix, i.e. for the @foo@ setting first looks for @foo@ and
--   then for @bootstrap.foo@.
bootstrapModifier' :: ReaderT C.Config IO (OptionModifier Ty.BootstrapConfig)
bootstrapModifier' = (fmap mconcat . T.sequenceA) mods where
      mods = [ liftModifier L.nodeConfig <$> nodeModifier' noPrefix
             , liftModifier L.poolConfig <$> poolModifier' noPrefix
             , restartEvery prefix
             , restartMinimumPeriod prefix
             , liftModifier L.nodeConfig <$> nodeModifier' prefix
             , liftModifier L.poolConfig <$> poolModifier' prefix
             ]
      prefix = ["bootstrap"]



-- | Same as "bootstrapModifier", but for the drawing server (using the
--   @drawing@ prefix).
drawingModifier' :: ReaderT C.Config IO (OptionModifier Ty.DrawingConfig)
drawingModifier' = (fmap mconcat . T.sequenceA) mods where
      mods = [ liftModifier L.nodeConfig <$> nodeModifier' noPrefix
             , liftModifier L.poolConfig <$> poolModifier' noPrefix
             , drawEvery prefix
             , drawFilename prefix
             , drawTimeout prefix
             , liftModifier L.nodeConfig <$> nodeModifier' prefix
             , liftModifier L.poolConfig <$> poolModifier' prefix
             ]
      prefix = ["drawing"]



-- | Same as "bootstrapModifier", but for the multi client (using the
--   @multi@ prefix).
multiModifier' :: ReaderT C.Config IO (OptionModifier Ty.MultiConfig)
multiModifier' = (fmap mconcat . T.sequenceA) mods where
      mods = [ liftModifier L.nodeConfig <$> nodeModifier' noPrefix
             , liftModifier L.poolConfig <$> poolModifier' noPrefix
             , liftModifier L.nodeConfig <$> nodeModifier' prefix
             , liftModifier L.poolConfig <$> poolModifier' prefix
             ]
      prefix = ["multi"]



-- | A prefix is what leads to an option in a hierarchy; they're similar to
--   parent directories. For example the expression "foo.bar.qux" corresponds to
--   @[\"foo\", \"bar\"] :: Prefixes@, with the option name being @qux@.
type Prefixes = [C.Name]



-- | Look up a certain setting, possibly with a list of parent prefixes.
lookupC :: C.Configured a
        => Prefixes -- ^ List of prefixes, e.g. ["foo", "bar"] for foo.bar.*
        -> C.Name   -- ^ Option name
        -> ReaderT C.Config IO (Maybe a)
lookupC prefixes name = ask >>= \cfg -> liftIO (C.lookup cfg fullName) where
      fullName | null prefixes = name
               | otherwise = Text.intercalate "." prefixes <> "." <> name



-- | Convert a field and a value to an 'OptionModifier' to set that field to
--   that value. 'mempty' if no value is given.
toSetter :: ASetter a a c b  -- ^ Lens to a field
         -> Maybe b          -- ^ New value of the field
         -> OptionModifier a -- ^ 'OptionModifier' to apply the lens
toSetter l (Just x) = OptionModifier (l .~ x)
toSetter _ Nothing  = mempty



-- | Get an option that cannot have wrong values (besides type mismatches).
--   For example, the verbosity option only supports a handful of words and not
--   all strings, so it is not a simple option. The number of neighbours on the
--   other hand can be any value.
getSimpleOption :: C.Configured b
                => ASetter a a c b
                -> C.Name
                -> Prefixes
                -> ReaderT C.Config IO (OptionModifier a)
getSimpleOption l name prefixes = fmap (toSetter l)
                                       (lookupC prefixes name)



-- Node config specific

serverPort, minNeighbours, maxNeighbours, maxChanSize, verbosity, hardBounces,
      acceptP, maxSoftBounces, shortTickRate, mediumTickRate, longTickRate,
      poolTimeout, floodMessageCache, bootstrapServers
            :: Prefixes -> ReaderT C.Config IO (OptionModifier Ty.NodeConfig)

serverPort        = getSimpleOption L.serverPort        "serverPort"
minNeighbours     = getSimpleOption L.minNeighbours     "minNeighbours"
maxNeighbours     = getSimpleOption L.maxNeighbours     "maxNeighbours"
maxChanSize       = getSimpleOption L.maxChanSize       "maxChanSize"
hardBounces       = getSimpleOption L.hardBounces       "hardBounces"
acceptP           = getSimpleOption L.acceptP           "acceptP"
maxSoftBounces    = getSimpleOption L.maxSoftBounces    "maxSoftBounces"
shortTickRate     = getSimpleOption L.shortTickRate     "shortTickRate"
mediumTickRate    = getSimpleOption L.mediumTickRate    "mediumTickRate"
longTickRate      = getSimpleOption L.longTickRate      "longTickRate"
poolTimeout       = getSimpleOption L.poolTimeout       "poolTimeout"
floodMessageCache = getSimpleOption L.floodMessageCache "floodMessageCache"

verbosity prefixes = fmap (toSetter L.verbosity) verbosity'

      where

      verbosity' :: ReaderT C.Config IO (Maybe Ty.Verbosity)
      verbosity' = fmap (maybe Nothing parseVerbosity)
                        (lookupC prefixes "verbosity")

      parseVerbosity :: String -> Maybe Ty.Verbosity
      parseVerbosity (map toLower -> x)
            | x == "mute"    = Just Ty.Mute
            | x == "quiet"   = Just Ty.Quiet
            | x == "default" = Just Ty.Default
            | x == "debug"   = Just Ty.Debug
            | x == "chatty"  = Just Ty.Chatty
            | otherwise      = Nothing

bootstrapServers prefixes = fmap appendBSS bootstrapServers'

      where

      appendBSS x = OptionModifier (L.bootstrapServers <>~ x)

      bootstrapServers' :: ReaderT C.Config IO (Set.Set Ty.To)
      bootstrapServers' = fmap m'valueToTo
                               (lookupC prefixes "bootstrapServers")

      m'valueToTo :: Maybe C.Value -> Set.Set Ty.To
      m'valueToTo = maybe Set.empty valueToTo

      -- Convert a "C.Value" to a "Set.Set" of "Ty.To" addresses.
      valueToTo :: C.Value -> Set.Set Ty.To
      valueToTo (C.String text) =
            either (const Set.empty)
                   Set.singleton
                   (parseAddrText text)
      valueToTo (C.List vals) = foldr go Set.empty vals where
            go (C.String text) xs = case parseAddrText text of
                  Right to -> Set.insert to xs
                  Left  _r -> xs
            go _else xs = xs
      valueToTo _else = Set.empty

      parseAddrText = AP.parseAddress . Text.unpack



-- Node pool specific

poolSize :: Prefixes -> ReaderT C.Config IO (OptionModifier Ty.PoolConfig)
poolSize = getSimpleOption L.poolSize "poolSize"



-- Bootstrap server specific

restartEvery, restartMinimumPeriod
      :: Prefixes -> ReaderT C.Config IO (OptionModifier Ty.BootstrapConfig)

restartEvery          = getSimpleOption L.restartEvery         "restartEvery"
restartMinimumPeriod  = getSimpleOption L.restartMinimumPeriod "restartMinimumPeriod"



-- Drawing server specific

drawEvery, drawFilename, drawTimeout
      :: Prefixes -> ReaderT C.Config IO (OptionModifier Ty.DrawingConfig)

drawEvery    = getSimpleOption L.drawEvery    "drawEvery"
drawFilename = getSimpleOption L.drawFilename "drawFilename"

drawTimeout prefixes =
      fmap (toSetter L.drawTimeout . fmap Ty.Microseconds)
           (lookupC prefixes "drawTimeout")
