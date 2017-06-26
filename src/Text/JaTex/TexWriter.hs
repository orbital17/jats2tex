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
import           Data.Char                           (isSpace)
import           Data.Either
import           Data.FileEmbed
import qualified Data.HashMap.Strict                 as HashMap
import qualified Data.List
import           Data.Maybe
import           Data.Text                           (Text)
import qualified Data.Text                           as Text
import qualified Data.Text.Encoding                  as Text (decodeUtf8,
                                                              encodeUtf8)
import qualified Data.Text.IO                        as Text
import qualified Data.Yaml                           as Yaml
import           JATSXML.HTMLEntities
import qualified Language.Haskell.Interpreter        as Hint
import qualified Language.Haskell.Interpreter.Unsafe as Hint
import           Language.Haskell.TH
import qualified Scripting.Lua                       as Lua
import qualified Scripting.LuaUtils                  as Lua
import           System.Directory
import           System.Environment
import           System.Exit
import           System.IO
import           System.IO.Unsafe
import           Text.JaTex.Parser
import           Text.JaTex.Template.Requirements
import           Text.JaTex.Template.TemplateInterp
import           Text.JaTex.Template.Types
import qualified Text.JaTex.Upgrade                  as Upgrade
import           Text.JaTex.Util
import           Text.LaTeX
import           Text.LaTeX.Base.Class
import qualified Text.LaTeX.Base.Parser              as LaTeX
import           Text.LaTeX.Base.Syntax
import qualified Text.Megaparsec                     as Megaparsec
import           Text.XML.Light

import           Paths_jats2tex

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
    when tsWarnings $ liftIO (hPutStrLn stderr ("[warning]" <> w))

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
  let contents = concatMap cleanUp d
  children <- mapM convertInlineNode contents
  let heads = sequence_ $ concatMap fst children
      bodies = sequence_ $ concatMap snd children
  add heads
  add bodies

convertNode
  :: MonadTex m
  => Content -> m (LaTeXT Identity ())
convertNode (Elem e) = do
  addComment "elem"
  ownAdded <- convertElem e
  -- when (render (runLaTeX ownAdded) /= mempty ||
  --       not (null (elChildren e))) $ add (fromString "\n")
  addComment "endelem"
  return ownAdded
convertNode (Text (CData CDataText str _))
  | str == "" || dropWhile isSpace str == "" = return mempty
convertNode (Text (CData CDataText str _)) = do
  addComment "cdata"
  let lstr = fromString str
  add lstr
  return lstr
convertNode (Text (CData _ str ml)) = do
  addComment "xml-cdata"
  let cs =
        map
          (\c ->
             case c of
               Elem el -> Elem el {elLine = ml}
               _       -> c)
          (parseXML str)
  mconcat <$> mapM convertNode cs
convertNode (CRef r) = do
  addComment "ref"
  let lr = fromString (fromMaybe r (crefToString r))
  add lr
  return lr

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
  => Element -> m (LaTeXT Identity ())
convertElem el@Element {..} = do
  TexState {tsTemplate} <- get
  commentEl
  templateContext <- getTemplateContext
  added <- case findTemplate (fst tsTemplate) templateContext of
    Nothing -> do
        _ <- run
        return mempty
    Just (_, t) -> do
      (h, b) <- templateApply t templateContext
      -- liftIO $ do
      --     putStrLn "Template:"
      --     print c
      --     putStrLn "Ouput:"
      --     Text.putStrLn (render (runLaTeX h))
      --     Text.putStrLn (render (runLaTeX b))
      addHead h
      add b
      return (h <> b)
  return added
    -- lookupAttr' k =
    --   attrVal <$> find (\Attr {attrKey} -> showQName attrKey == k) elAttribs
  where
    n = qName elName
    commentEl =
      addComment
        (Text.pack
           (" <" <> n <> " " <> humanAttrs <> "> (" <> maybe "" show elLine <>
            ")"))
    humanAttrs =
      unwords $
      map
        (\(Attr attrKey attrValue) -> showQName attrKey <> "=" <> show attrValue)
        elAttribs
    -- commentEndEl =
    --   add $
    --   (comment (Text.pack ("</" <> n <> "> (" <> maybe "" show elLine <> "))")))
    getTemplateContext = do
      (h, i) <- convertInlineChildren el
      st <- get
      l <- liftIO Lua.newstate
      return
        TemplateContext
        {tcLuaState = l, tcState = st, tcHeads = h, tcBodies = i, tcElement = el}
    run =
      case elContent of
        [] -> return (textell mempty)
        _  -> do
            logWarning ("Ignoring tag " <> n)
            convertChildren el

removeSpecial :: String -> String
removeSpecial =
  map
    (\c ->
       if c == ':'
         then '-'
         else c)

convertInlineNode
  :: MonadTex m =>
     Content -> m ([LaTeXT Identity ()], [LaTeXT Identity ()])
convertInlineNode c = do
  st <- get
  (newState, _, _) <-
    runTexWriter (st {tsHeadRev = mempty, tsBodyRev = mempty}) (convertNode c)
  return (tsHead newState, tsBody newState)

convertInlineChildren :: MonadTex m => Element -> m ([LaTeXT Identity ()], [LaTeXT Identity ()])
convertInlineChildren el = do
  st <- get
  (newState, _, _) <-
    runTexWriter (st {tsHeadRev = mempty, tsBodyRev = mempty}) (convertChildren el)
  return (tsHead newState, tsBody newState)

convertInlineElem :: MonadTex m => Element -> m ([LaTeXT Identity ()], [LaTeXT Identity ()])
convertInlineElem el = do
  st <- get
  (newState, _, _) <- runTexWriter (st {tsHeadRev = mempty, tsBodyRev = mempty}) (void (convertElem el))
  return (tsHead newState, tsBody newState)

convertChildren :: MonadTex m => Element -> m (LaTeXT Identity ())
convertChildren Element {elContent} = mconcat <$> mapM convertNode elContent

comm2
  :: LaTeXC l
  => String -> l -> l -> l
comm2 str = liftL2 $ \l1 l2 -> TeXComm str [FixArg l1, FixArg l2]

begin
  :: Monad m
  => Text -> LaTeXT m () -> LaTeXT m ()
begin n c = between c (raw ("\\begin{" <> n <> "}")) (raw ("\\end{" <> n <> "}"))

-- Template Execution

templateApply
  :: MonadTex m
  => TemplateNode (StateT TexState IO)
  -> TemplateContext
  -> m (LaTeXT Identity (), LaTeXT Identity ())
templateApply TemplateNode {templateLaTeX, templateLaTeXHead} tc =
    (,) <$> applyTemplateToEl templateLaTeXHead tc <*>
    applyTemplateToEl templateLaTeX tc

runPredicate :: NodeSelector -> NodeSelector -> Bool
runPredicate s t = t == s


findTemplate :: Template -> TemplateContext -> Maybe (ConcreteTemplateNode, TemplateNode (StateT TexState IO))
findTemplate ts el = run ts el
  where
    run (Template []) _ = Nothing
    run (Template (p@(_, TemplateNode {templatePredicate}):ps)) e =
      if runPredicate templatePredicate targetName
        then Just p
        else run (Template ps) e
    targetName = showQName (elName (tcElement el))

runTemplate
  :: MonadTex m
  => Template
  -> TemplateContext
  -> m (Maybe ((ConcreteTemplateNode, TemplateNode (StateT TexState IO)), (LaTeXT Identity (), LaTeXT Identity ())))
runTemplate ts el =
  case findTemplate ts el of
    Nothing -> return Nothing
    Just p@(_, t) -> do
      -- liftIO $ hPutStrLn stderr "Found template, applying..."
      r <- templateApply t el
      return $ Just (p, r)

applyTemplateToEl :: MonadTex m => PreparedTemplate (StateT TexState IO) -> TemplateContext -> m (LaTeXT Identity ())
applyTemplateToEl l e = do
  rs <- mapM (evalNode e) l
  return $ textell $ TeXRaw $ Text.concat rs

evalNode
  :: MonadTex m
  => TemplateContext -> PreparedTemplateNode (StateT TexState IO) -> m Text
evalNode _ (PreparedTemplatePlain t) = return t
evalNode e (PreparedTemplateVar "heads") =
  return $ render (runLaTeX (sequence_ (tcHeads e)))
evalNode e (PreparedTemplateVar "bodies") =
  return $ render (runLaTeX (sequence_ (tcBodies e)))
evalNode e (PreparedTemplateVar "children") =
  return $ render (runLaTeX (sequence_ (tcChildren e)))
evalNode _ (PreparedTemplateVar "requirements") =
  return $ render (runLaTeX requirements)
evalNode _ (PreparedTemplateVar _) = return ""
evalNode e (PreparedTemplateLua run) = do
    (_, _, result) <- liftIO $ runTexWriter (tcState e) (run e)
    return (render (runLaTeX result))
evalNode e (PreparedTemplateExpr runner) = do
  let children = tcChildren e
      runFind = mkFindChildren e
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
          (findChildren (QName (Text.unpack name) Nothing Nothing) tcElement)
      let heads = sequence_ (concatMap fst inlines) :: LaTeXT Identity ()
          bodies = sequence_ (concatMap snd inlines) :: LaTeXT Identity ()
      return (heads <> bodies)

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
        luaRunner context@TemplateContext {..} =
          liftIO $
            -- putStrLn ("Running lua interpolation (" <> show t <> ")")
           do
            let l = tcLuaState
            Lua.openlibs l
            Lua.registerhsfunction
              l
              "children"
              (return (render (runLaTeX (sequence_ (tcChildren context)))) :: IO Text)
            Lua.registerhsfunction l "find" luaFindChildren
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
            luaAttr :: ByteString -> IO (Maybe ByteString)
            luaAttr name =
              return $
              ByteString.pack <$>
              lookupAttr (QName sname Nothing Nothing) (elAttribs tcElement)
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
            luaFindChildren :: ByteString -> IO ByteString
            luaFindChildren name = do
              inlines <-
                execTexWriter tcState $
                mapM
                  convertInlineElem
                  (findChildren
                     (QName (ByteString.unpack name) Nothing Nothing)
                     tcElement)
              let heads =
                    sequence_ (concatMap fst inlines) :: LaTeXT Identity ()
                  bodies =
                    sequence_ (concatMap snd inlines) :: LaTeXT Identity ()
              return (Text.encodeUtf8 (render (runLaTeX (heads <> bodies))))
    doPrepare (TemplateExpr e) = do
      runner <-
        do erunner <-
             do hPutStrLn stderr ("Compiling interpolation (" <> show i <> ")")
                homeDir <- getHomeDirectory
                let args =
                      [ "-no-user-package-db"
                      -- , "-package-db /Users/yamadapc/program/github.com/beijaflor-io/jats2tex/.stack-work/install/x86_64-osx/lts-8.0/8.0.2/pkgdb"
                      ] <>
                      [ "-package-db " <> db
                      | db <-
                          [ homeDir <>
                            "/program/github.com/beijaflor-io/jats2tex/.stack-work/install/x86_64-osx/lts-8.0/8.0.2/pkgdb"
                          , homeDir <>
                            "/.stack/snapshots/x86_64-osx/lts-8.0/8.0.2/pkgdb"
                          , homeDir <>
                            "/.stack/programs/x86_64-osx/ghc-8.0.2/lib/ghc-8.0.2/package.conf.d"
                          ]
                      ]
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
  -- case LaTeX.parseLaTeX templateContent of
  --   Right l -> do
  --     case templateHead of
  --       "" -> do
  --         prepared <- liftIO $ prepareInterp (render l)
  --         return $
  --           Right
  --             TemplateNode
  --             { templatePredicate = Text.unpack templateSelector
  --             , templateLaTeXHead = mempty
  --             , templateLaTeX = prepared
  --             }
  --       _ ->
  --         case LaTeX.parseLaTeX templateHead of
  --           Right h -> do
              -- preparedH <- liftIO $ prepareInterp (render h)
              -- preparedL <- liftIO $ prepareInterp (render l)
              preparedH <- liftIO $ prepareInterp templateHead
              preparedL <- liftIO $ prepareInterp templateContent
              return $
                Right
                  TemplateNode
                  { templatePredicate = Text.unpack templateSelector
                  , templateLaTeXHead = preparedH
                  , templateLaTeX = preparedL
                  }
    --         Left e -> return $ Left (Text.pack (show e))
    -- Left e -> return $ Left (Text.pack (show e))

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

defaultTemplate :: (Template, FilePath)
defaultTemplate = unsafePerformIO $ do
    let s = $(do fp <- runIO $ getDataFileName "./default.yaml"
                 embedFile fp)
        fp = "default.yaml"
    t <- parseTemplate fp s
    return (t, fp)
{-# NOINLINE defaultTemplate #-}
