{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
module Text.JaTex.TexWriter
  where

import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.Identity
import           Control.Monad.IO.Class
import           Control.Monad.State
import           Control.Monad.Writer
import           Crypto.Hash
import           Data.Aeson                          (Result (..), Value (..),
                                                      fromJSON)
import           Data.ByteString                     (ByteString)
import qualified Data.ByteString                     as ByteStringS
import qualified Data.ByteString.Char8               as ByteString (pack,
                                                                    unpack)
import qualified Data.ByteString.Lazy.Char8          as ByteStringL
import           Data.Either
import           Data.FileEmbed
import qualified Data.HashMap.Strict                 as HashMap
import           Data.Maybe
import           Data.Text                           (Text)
import qualified Data.Text                           as Text
import qualified Data.Text.Encoding                  as Text (decodeUtf8,
                                                              encodeUtf8)
import qualified Data.Text.IO                        as Text
import qualified Data.Tree.NTree.TypeDefs            as HXT
import qualified Data.Yaml                           as Yaml
import qualified Language.Haskell.Interpreter        as Hint
import qualified Language.Haskell.Interpreter.Unsafe as Hint
import qualified Scripting.Lua                       as Lua
import qualified Scripting.LuaUtils                  as Lua
import           System.Environment
import           System.Exit
import           System.IO
import           System.IO.Unsafe
import           System.Process
import           Text.JaTex.Parser
import           Text.JaTex.Template.Requirements
import           Text.JaTex.Template.TemplateInterp
import           Text.JaTex.Template.Types
import qualified Text.JaTex.Upgrade                  as Upgrade
import           Text.JaTex.Util
import           Text.LaTeX
import           Text.LaTeX.Base.Class
import           Text.LaTeX.Base.Syntax
import qualified Text.Megaparsec                     as Megaparsec
import qualified Text.XML.HXT.Core                   as HXT
import qualified Text.XML.HXT.XPath                  as HXT
-- import           Text.XML.Light
import           TH.RelativePaths

emptyState :: TexState
emptyState = TexState { tsBodyRev = mempty
                      , tsHeadRev = mempty
                      , tsMetadata = mempty
                      , tsTemplate = defaultTemplate
                      , tsFileName = ""
                      , tsWarnings = True
                      , tsDebug = False
                      }

logWarning :: (MonadState TexState m, MonadIO m) => String -> m ()
logWarning w = do
    TexState{tsWarnings} <- get
    when tsWarnings $ liftIO (hPutStrLn stderr ("[warning] " <> w))

tsHead :: TexState -> [LaTeXT Identity ()]
tsHead = reverse . tsHeadRev

tsBody :: TexState -> [LaTeXT Identity ()]
tsBody = reverse . tsBodyRev

execTexWriter :: Monad m => TexState -> StateT TexState m b -> m b
execTexWriter s e = do
    (_, _, r) <- runTexWriter s e
    return r

runTexWriter
  :: Monad m
  => TexState -> StateT TexState m t -> m (TexState, LaTeX, t)
runTexWriter st w = do
  (o, newState) <- runStateT w st
  let hCmds = tsHead newState
      bCmds = tsBody newState
      (_, r) = runIdentity $ runLaTeXT (sequence_ (hCmds <> bCmds))
  return (newState, r, o)

convert
  :: (MonadIO m, MonadMask m) =>
     String -> (Template, FilePath) -> JATSDoc -> Bool -> m LaTeX
convert fp tmp i w = do
  liftIO $ do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    hPutStrLn stderr $
      unlines
        [ "jats2tex@" <> Upgrade.versionNumber Upgrade.currentVersion
        , "Parsed Template:  " <> snd tmp
        , "Converting Input: " <> fp
        ]
  debug <- isJust <$> liftIO (lookupEnv "JATS2TEX_DEBUG")
  (_, !t, _) <-
    runTexWriter
      emptyState {tsFileName = fp, tsTemplate = tmp, tsDebug = debug, tsWarnings = w}
      (jatsXmlToLaTeX i)
  return t

jatsXmlToLaTeX
  :: MonadTex m
  => JATSDoc -> m ()
jatsXmlToLaTeX d = do
  add $
    comment
      (Text.pack
         (" Generated by jats2tex@" <>
          Upgrade.versionNumber Upgrade.currentVersion <>
          ":" <>
          fromMaybe "" (do
             binHash <- Upgrade.versionHash Upgrade.currentVersion
             digHash <- digestFromByteString binHash :: Maybe (Digest SHA1)
             return (ByteString.unpack (digestToHexByteString digHash)))))
  let contents = d -- concatMap cleanUp d
  children <- mapM convertInlineNode contents
  let heads = sequence_ $ concatMap fst children
      bodies = sequence_ $ concatMap snd children
  add heads
  add bodies

convertNode
  :: MonadTex m
  => HXT.XmlTree -> m (LaTeXT Identity ())
convertNode fullNode@(HXT.NTree node _) =
  case node of
    HXT.XTag _ _ -> do
      addComment "tag"
      ownAdded <- convertElem fullNode
      addComment "endelem"
      return ownAdded
    HXT.XText str ->
      if HXT.stringTrim str == mempty
        then return mempty
        else do
          let lstr = fromString str
          add lstr
          return lstr
    HXT.XBlob blob -> do
      let lstr = fromString (ByteStringL.unpack blob)
      add lstr
      return lstr
    HXT.XAttr _n -> return mempty
    HXT.XDTD _dtdElem _attrs -> return mempty
    HXT.XError _level _err -> return mempty
    HXT.XPi _name _attrs -> return mempty
    HXT.XCdata _i -> return mempty
    HXT.XCmt _cmt -> return mempty
    HXT.XCharRef _i -> return mempty
    HXT.XEntityRef _i -> return mempty

addHead :: MonadState TexState m => LaTeXT Identity () -> m ()
addHead m = modify (\ts -> ts { tsHeadRev = m:tsHeadRev ts
                              })

add :: MonadState TexState m => LaTeXT Identity () -> m ()
add m = modify (\ts -> ts { tsBodyRev = m:tsBodyRev ts
                          })

addComment :: MonadState TexState m => Text -> m ()
addComment c = do
  isDebug <- tsDebug <$> get
  when isDebug (add (comment c))

convertElem
  :: MonadTex m
  => HXT.XmlTree -> m (LaTeXT Identity ())
convertElem el@(HXT.NTree (HXT.XTag name attrs) children) = do
  TexState {tsTemplate} <- get
  commentEl
  liftIO $ hPutStrLn stderr (show $ ("convertElem", HXT.qualifiedName name))
  case findTemplate (fst tsTemplate) el of
    Nothing -> do
      _ <- run
      return mempty
    Just (sub, _, t) -> do
      templateContext <- getTemplateContext
      liftIO $ print ("findTemplate", elementName el, "found subtree", sub)
      rs <- forM sub $ \x -> templateApply t templateContext { tcElement = x }
      let h = mapM_ fst rs
          b = mapM_ snd rs
      addHead h
      add b
      return (h <> b)
  where
    commentEl =
      addComment
        (Text.pack (" <" <> HXT.qualifiedName name <> " " <> humanAttrs <> ">"))
    humanAttrs =
      unwords $
      map
        (\(HXT.NTree (HXT.XAttr attrKey) [HXT.NTree (HXT.XText attrValue) _]) ->
           HXT.qualifiedName attrKey <> "=" <> show attrValue)
        attrs
    getTemplateContext = do
      st <- get
      l <- liftIO Lua.newstate
      return
        TemplateContext
        { tcLuaState = l
        , tcState = st
        , tcElement = el
        }
    run =
      case children of
        [] -> return (textell mempty)
        _ -> do
          logWarning ("Ignoring tag " <> HXT.qualifiedName name)
          convertChildren el
convertElem e = fail $ "convertElem needs XML elements but got (" <> show e <> ")"

removeSpecial :: String -> String
removeSpecial =
  map
    (\c ->
       if c == ':'
         then '-'
         else c)

convertInlineNode
  :: MonadTex m
  => HXT.XmlTree -> m ([LaTeXT Identity ()], [LaTeXT Identity ()])
convertInlineNode c = do
  st <- get
  (newState, _, _) <-
    runTexWriter (st {tsHeadRev = mempty, tsBodyRev = mempty}) (convertNode c)
  return (tsHead newState, tsBody newState)

convertInlineChildren :: MonadTex m => HXT.XmlTree -> m ([LaTeXT Identity ()], [LaTeXT Identity ()])
convertInlineChildren el = do
  st <- get
  (newState, _, _) <-
    runTexWriter (st {tsHeadRev = mempty, tsBodyRev = mempty}) (convertChildren el)
  return (tsHead newState, tsBody newState)

convertInlineElem :: MonadTex m => HXT.XmlTree -> m ([LaTeXT Identity ()], [LaTeXT Identity ()])
convertInlineElem el = do
  st <- get
  (newState, _, _) <- runTexWriter (st {tsHeadRev = mempty, tsBodyRev = mempty}) (void (convertElem el))
  return (tsHead newState, tsBody newState)

convertChildren :: MonadTex m => HXT.XmlTree -> m (LaTeXT Identity ())
convertChildren (HXT.NTree _ elContent) = mconcat <$> mapM convertNode elContent

comm2
  :: LaTeXC l
  => String -> l -> l -> l
comm2 str = liftL2 $ \l1 l2 -> TeXComm str [FixArg l1, FixArg l2]

begin
  :: Monad m
  => Text -> LaTeXT m () -> LaTeXT m ()
begin n c = between c (raw ("\\begin{" <> n <> "}")) (raw ("\\end{" <> n <> "}"))

-- Template Execution

elementName (HXT.NTree (HXT.XTag n _) _) = HXT.qualifiedName n
elementName _                            = "<none>"

templateApply
  :: MonadTex m
  => TemplateNode (StateT TexState IO)
  -> TemplateContext
  -> m (LaTeXT Identity (), LaTeXT Identity ())
templateApply TemplateNode {templateLaTeX, templateLaTeXHead} tc = do
    (heads, bodies) <- convertInlineChildren (tcElement tc)
    hresult <- applyTemplateToEl templateLaTeXHead tc (heads, bodies)
    bresult <- applyTemplateToEl templateLaTeX tc (heads, bodies)
    return (hresult, bresult)

runPredicate :: NodeSelector -> NodeSelector -> Bool
runPredicate s t = t == s


findTemplate :: Template -> HXT.XmlTree -> Maybe ([HXT.XmlTree], ConcreteTemplateNode, TemplateNode (StateT TexState IO))
findTemplate ts e = run ts
  where
    run (Template []) = Nothing
    run (Template ((ct, t@TemplateNode {templatePredicate}):ps)) =
      let xpathR = HXT.getXPathSubTrees templatePredicate e
      in case xpathR of
           []  -> run (Template ps)
           sub -> Just (sub, ct, t)

elChildren :: HXT.XmlTree -> [HXT.XmlTree]
elChildren (HXT.NTree _ c) = filter isElem c
  where
    isElem (HXT.NTree (HXT.XTag _ _) _) = True
    isElem _                            = False

elAttribs :: HXT.XmlTree -> [HXT.XmlTree]
elAttribs (HXT.NTree (HXT.XTag _ attrs) _) = attrs
elAttribs _                                = []

lookupAttr :: String -> [HXT.XmlTree] -> Maybe String
lookupAttr n (a:as) =
  case a of
    HXT.NTree (HXT.XAttr attrKey) (HXT.NTree (HXT.XText v) _:_)
      | attrKey == HXT.mkName n -> Just v
    _ -> lookupAttr n as
lookupAttr _ [] = Nothing

applyTemplateToEl l e (heads, bodies) = do
  rs <- mapM (\i -> evalNode e i (heads, bodies)) l
  return $ textell $ TeXRaw $ Text.concat rs

-- evalNode
--   :: MonadTex m
--   => TemplateContext -> PreparedTemplateNode (StateT TexState IO) -> m Text
evalNode e ptn (heads, bodies) = do
  let children = heads <> bodies
  case ptn of
    (PreparedTemplatePlain t) -> return t
    (PreparedTemplateVar "heads") -> return $ render . runLaTeX . sequence_ $ heads
    (PreparedTemplateVar "bodies") -> return $ render . runLaTeX . sequence_ $ bodies
    (PreparedTemplateVar "children") -> return $ render . runLaTeX . sequence_ $ children
    (PreparedTemplateVar "requirements") -> return $ render (runLaTeX requirements)
    (PreparedTemplateVar _) -> return ""
    (PreparedTemplateLua run) -> do
        (_, _, result) <- liftIO $ runTexWriter (tcState e) (run e (heads, bodies))
        return (render (runLaTeX result))
    (PreparedTemplateExpr runner) -> do
        let runFind = mkFindChildren e
            wtr = runner e children runFind
        (_, _, result) <- liftIO $ runTexWriter (tcState e) wtr
        return (render (runLaTeX result))
  where
    mkFindChildren
      :: MonadTex m
      => TemplateContext -> Text -> m (LaTeXT Identity ())
    mkFindChildren TemplateContext {tcElement} name = do
      inlines <-
        mapM
          convertInlineElem
          (findChildren (HXT.mkName (Text.unpack name)) tcElement)
      let heads = sequence_ (concatMap fst inlines) :: LaTeXT Identity ()
          bodies = sequence_ (concatMap snd inlines) :: LaTeXT Identity ()
      return (heads <> bodies)

findChildren :: HXT.QName -> HXT.XmlTree -> [HXT.XmlTree]
findChildren n (HXT.NTree _ cs) = filter helper cs
  where
    helper (HXT.NTree (HXT.XTag t _) _) = t == n
    helper _                            = False

prepareInterp :: Text -> IO (PreparedTemplate (StateT TexState IO))
prepareInterp i =
  case Megaparsec.parseMaybe interpParser i of
    Nothing     -> return []
    Just interp -> mapM doPrepare interp
  where
    doPrepare :: TemplateInterpNode
              -> IO (PreparedTemplateNode (StateT TexState IO))
    doPrepare (TemplateVar t) = return $ PreparedTemplateVar t
    doPrepare (TemplatePlain t) = return $ PreparedTemplatePlain t
    doPrepare (TemplateLua t) = return $ PreparedTemplateLua luaRunner
      where
        luaRunner context@TemplateContext {..} (heads, bodies) =
          liftIO $
            -- putStrLn ("Running lua interpolation (" <> show t <> ")")
           do
            let l = tcLuaState
            Lua.openlibs l
            Lua.registerhsfunction l "children" luaChildren
            Lua.registerhsfunction l "find" luaFindChildren
            Lua.registerhsfunction l "findAll" luaFindAll
            Lua.registerhsfunction l "attr" luaAttr
            Lua.registerhsfunction l "elements" luaElements
            Lua.luaDoString
              l
              (Text.unpack
                 (Text.unlines
                    (["function jats2tex_module_wrapper()"] <>
                     map ("  " <>) (Text.lines t) <>
                     ["end"])))
            result <- Lua.callfunc l "jats2tex_module_wrapper"
            -- putStrLn "Result:"
            -- print result
            return (raw (Text.decodeUtf8 result))
          where
            luaChildren :: IO ByteString
            luaChildren = do
              -- c <- execTexWriter tcState (sequence (heads <> bodies))
              return $ Text.encodeUtf8 $ render . runLaTeX . sequence_ $ (heads <> bodies)
            luaAttr :: ByteString -> IO ByteString
            luaAttr name =
              return $
              ByteString.pack $
              fromMaybe "" $ lookupAttr sname (elAttribs tcElement)
              where
                sname = Text.unpack (Text.decodeUtf8 name)
            luaElements :: IO [ByteString]
            luaElements =
              execTexWriter tcState $ do
                r <- mapM convertInlineElem (elChildren tcElement)
                let heads = concatMap fst r :: [LaTeXT Identity ()]
                    bodies = concatMap snd r
                let ts = heads <> bodies
                    latexs = map (render . snd . runIdentity . runLaTeXT) ts
                    els =
                      filter ((/= mempty) . Text.strip . fst) (zip latexs ts)
                return (map (Text.encodeUtf8 . fst) els)
            luaFindAll :: ByteString -> IO [ByteString]
            luaFindAll name = do
              inlines <-
                execTexWriter tcState $
                mapM
                  convertInlineElem
                  (findChildren (HXT.mkName (ByteString.unpack name)) tcElement)
              let heads = concatMap fst inlines
                  bodies = concatMap snd inlines
              return $ map (Text.encodeUtf8 . render . runLaTeX) (heads <> bodies)
            luaFindChildren :: ByteString -> IO ByteString
            luaFindChildren name = do
              inlines <-
                execTexWriter tcState $
                mapM
                  convertInlineElem
                  (findChildren (HXT.mkName (ByteString.unpack name)) tcElement)
              let heads =
                    sequence_ (concatMap fst inlines) :: LaTeXT Identity ()
                  bodies =
                    sequence_ (concatMap snd inlines) :: LaTeXT Identity ()
              return (Text.encodeUtf8 (render (runLaTeX (heads <> bodies))))
    doPrepare (TemplateExpr e) = do
      runner <-
        do erunner <-
             do globalPkgDb <-
                  readCreateProcess
                    (shell "stack path --global-pkg-db --resolver lts-8.0")
                    ""
                snapshotPkgDb <-
                  readCreateProcess
                    (shell "stack path --snapshot-pkg-db --resolver lts-8.0")
                    ""
                let pkgDbs = [globalPkgDb, snapshotPkgDb]
                hPutStrLn
                  stderr
                  ("Compiling interpolation (" <> show i <>
                   " - Package Databases: " <>
                   show pkgDbs <>
                   ")")
                let args =
                      ["-no-user-package-db"] <>
                      ["-package-db " <> db | db <- pkgDbs]
                Hint.unsafeRunInterpreterWithArgs args $ do
                  Hint.reset
                  Hint.set
                      -- Hint.searchPath Hint.:=
                      -- [ "/Users/yamadapc/program/github.com/beijaflor-io/jats2tex"
                      -- ]
                    []
                  Hint.set
                    [Hint.languageExtensions Hint.:= [Hint.OverloadedStrings]]
                  Hint.setImports
                    [ "Prelude"
                    , "Control.Monad.State"
                    , "Text.JaTex.Template.Types"
                    , "Text.JaTex.Template.TemplateInterp.Helpers"
                    ]
                  let runnerExpr =
                        "\\context children findChildren ->" <> Text.unpack e
                      runnerExprType = Hint.as :: ExprType (StateT TexState IO)
                  Hint.interpret runnerExpr runnerExprType
           case erunner of
             Left err -> do
               hPrint stderr err
               exitWith (ExitFailure 1)
             Right runner -> return runner
      return $ PreparedTemplateExpr runner

parseTemplateNode :: ConcreteTemplateNode -> IO (Either Text (TemplateNode (StateT TexState IO)))
parseTemplateNode ConcreteTemplateNode {..} = do
  preparedH <- liftIO $ prepareInterp templateHead
  preparedL <- liftIO $ prepareInterp templateContent
  return $
    Right
      TemplateNode
      { templatePredicate = Text.unpack templateSelector
      , templateLaTeXHead = preparedH
      , templateLaTeX = preparedL
      }

mergeEithers :: [Either a b] -> Either [a] [b]
mergeEithers [] = Right []
mergeEithers (Left e:es) = Left (e : lefts es)
mergeEithers (Right e:es) =
  case mergeEithers es of
    lfs@(Left _) -> lfs
    (Right rs)   -> Right (e : rs)

isTruthy :: Value -> Bool
isTruthy (Bool b)   = b
isTruthy (Number n) = n /= 0
isTruthy (Object o) = o /= mempty
isTruthy (String s) = s /= mempty
isTruthy Null       = False
isTruthy (Array _)  = True

parseCTemplateFromJson :: Value -> Either [Text] [ConcreteTemplateNode]
parseCTemplateFromJson (Object o) =
  mergeEithers $ HashMap.foldrWithKey parsePair [] o
  where
    parsePair k v m =
      let mctn = fromJSON v :: Result ConcreteTemplateNode
      in case mctn of
           Error e     -> Left (Text.pack e) : m
           Success ctn -> Right ctn {templateSelector = k} : m
parseCTemplateFromJson _ = Left ["Template inválido, o formato esperado é `seletor: 'template'`"]

parseTemplateFile :: FilePath -> IO Template
parseTemplateFile fp = parseTemplate fp =<< ByteStringS.readFile fp

parseTemplate :: FilePath -> Data.ByteString.ByteString -> IO Template
parseTemplate fp s = do
  let v = Yaml.decode s
  v' <-
    case v of
      Nothing -> error $ "Couldn't parse " <> fp
      Just i  -> return i
  case parseCTemplateFromJson v' of
    Left errs -> do
      forM_ errs $ \err -> Text.hPutStrLn stderr err
      exitWith (ExitFailure 1)
    Right cs -> do
      es <- mapM parseTemplateNode cs
      case mergeEithers es of
        Left errs -> do
          forM_ errs $ \err -> Text.hPutStrLn stderr err
          exitWith (ExitFailure 1)
        Right ns -> return $ Template $ zip cs ns

defaultTemplateContents :: ByteString
defaultTemplateContents = $(bsToExp =<< qReadFileBS "./default.yaml")

defaultTemplate :: (Template, FilePath)
defaultTemplate = unsafePerformIO $ do
    let s = defaultTemplateContents
        fp = "default.yaml"
    t <- parseTemplate fp s
    return (t, fp)
{-# NOINLINE defaultTemplate #-}
