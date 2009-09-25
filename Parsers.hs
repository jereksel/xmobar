{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Xmobar.Parsers
-- Copyright   :  (c) Andrea Rossato
-- License     :  BSD-style (see LICENSE)
--
-- Maintainer  :  Andrea Rossato <andrea.rossato@unibz.it>
-- Stability   :  unstable
-- Portability :  unportable
--
-- Parsers needed for Xmobar, a text based status bar
--
-----------------------------------------------------------------------------

module Parsers
    ( parseString
    , parseTemplate
    , parseConfig
    ) where

import Config
import Commands
import Runnable
import Text.ParserCombinators.Parsec hiding ((<|>))
import qualified Text.ParserCombinators.Parsec as Parsec
import qualified Data.Map as Map

import Data.Foldable (sequenceA_)
import Data.List (find,inits,tails)
import Control.Applicative.Permutation (optAtom, runPermsSep)
import Control.Applicative hiding (many)
import Control.Monad.Writer
import Data.Either

-- | Runs the string parser
parseString :: Config -> String -> IO [(String, String)]
parseString c s =
    case parse (stringParser (fgColor c)) "" s of
      Left  _ -> return [("Could not parse string: " ++ s, fgColor c)]
      Right x -> return (concat x)

-- | Gets the string and combines the needed parsers
stringParser :: String -> Parser [[(String, String)]]
stringParser c = manyTill (textParser c <|> colorParser) eof

-- | Parses a maximal string without color markup.
textParser :: String -> Parser [(String, String)]
textParser c = do s <- many1 $
                    noneOf "<" <|>
                    ( try $ notFollowedBy' (char '<')
                                           (string "fc=" <|> string "/fc>" ) )
                  return [(s, c)]

-- | Wrapper for notFollowedBy that returns the result of the first parser.
--   Also works around the issue that, at least in Parsec 3.0.0, notFollowedBy
--   accepts only parsers with return type Char.
notFollowedBy' :: Parser a -> Parser b -> Parser a
notFollowedBy' p e = do x <- p
                        notFollowedBy (e >> return '*')
                        return x

-- | Parsers a string wrapped in a color specification.
colorParser :: Parser [(String, String)]
colorParser = do
  c <- between (string "<fc=") (string ">") colors
  s <- manyTill (textParser c <|> colorParser) (try $ string "</fc>")
  return (concat s)

-- | Parses a color specification (hex or named)
colors :: Parser String
colors = many1 (alphaNum <|> char ',' <|> char '#')

-- | Parses the output template string
templateStringParser :: Config -> Parser (String,String,String)
templateStringParser c = do
  s   <- allTillSep c
  com <- templateCommandParser c
  ss  <- allTillSep c
  return (com, s, ss)

-- | Parses the command part of the template string
templateCommandParser :: Config -> Parser String
templateCommandParser c =
  let chr = char . head . sepChar
  in  between (chr c) (chr c) (allTillSep c)

-- | Combines the template parsers
templateParser :: Config -> Parser [(String,String,String)]
templateParser = many . templateStringParser

-- | Actually runs the template parsers
parseTemplate :: Config -> String -> IO [(Runnable,String,String)]
parseTemplate c s =
    do str <- case parse (templateParser c) "" s of
                Left _  -> return [("","","")]
                Right x -> return x
       let cl = map alias (commands c)
           m  = Map.fromList $ zip cl (commands c)
       return $ combine c m str

-- | Given a finite "Map" and a parsed templatet produces the
-- | resulting output string.
combine :: Config -> Map.Map String Runnable -> [(String, String, String)] -> [(Runnable,String,String)]
combine _ _ [] = []
combine c m ((ts,s,ss):xs) = (com, s, ss) : combine c m xs
    where com  = Map.findWithDefault dflt ts m
          dflt = Run $ Com ts [] [] 10

allTillSep :: Config -> Parser String
allTillSep = many . noneOf . sepChar

instance Applicative (GenParser tok st) where
    pure = return
    (<*>) = ap

instance Alternative (GenParser tok st) where
    (<|>) x y = (Parsec.<|>) (try x) y
    empty = pzero

readsToParsec :: Read b => CharParser st b
readsToParsec = do
    pos0 <- getPosition
    input <- getInput
    case reads input of
        (result,rest):_ -> do
            sequenceA_ $ do
                  ls <- fmap (lines . fst) . find ((==rest) . snd)
                            $ zip (inits input) (tails input)
                  lastLine <- safeLast ls
                  return $ setPosition
                      . flip setSourceColumn (length lastLine)
                      . flip incSourceLine (length ls - 1) $ pos0
            setInput rest
            return result
        _ -> setInput input >> fail "readsToParsec failed"

safeLast :: [a] -> Maybe a
safeLast [] = Nothing
safeLast xs = Just (last xs)

liftM9 :: (Monad m) => (a1 -> a2 -> a3 -> a4 -> a5 -> a6 -> a7 -> a8 -> a9 -> b) ->
          m a1 -> m a2 -> m a3 -> m a4 -> m a5 -> m a6 -> m a7 -> m a8 -> m a9 -> m b
liftM9 fun a b c d e f g h i
    = fun `liftM` a `ap` b `ap` c `ap` d `ap` e `ap` f `ap` g `ap` h `ap` i

-- | Parse the config, logging a list of fields that were missing and replaced
-- by the default definition.
parseConfig :: MonadWriter [String] m => String -> Either ParseError (m Config)
parseConfig = flip parse "Config" $ sepEndSpaces ["Config","{"]
                                    *> perms <* wrapSkip (string "}") <* eof
    where
      perms = runPermsSep (wrapSkip $ string ",") $ liftM9 Config
        <$> withDef font         "font"          strField
        <*> withDef bgColor      "bgColor"       strField
        <*> withDef fgColor      "fgColor"       strField
        <*> withDef position     "position"     (field readsToParsec)
        <*> withDef lowerOnStart "lowerOnStart" (field parseEnum    )
        <*> withDef commands     "commands"     (field readsToParsec)
        <*> withDef sepChar      "sepChar"       strField
        <*> withDef alignSep     "alignSep"      strField
        <*> withDef template     "template"      strField

      wrapSkip x = many space *> x <* many space
      sepEndSpaces = mapM_ (\s -> string s <* many space)

      withDef ext name parser = optAtom (do tell [name]; return $ ext defaultConfig)
                                        (liftM return $ parser name)

      parseEnum = choice $ map (\x -> x <$ string (show x)) [minBound .. maxBound]

      strField name = flip field name $ between (char '"') (char '"') (many1 . satisfy $ (/= '"'))
      field cont name = sepEndSpaces [name,"="] *> cont
