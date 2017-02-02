{-# LANGUAGE OverloadedStrings #-}

module Parser (parseAgdaInput, parseTex, parseTrie) where

import Types

import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Attoparsec.Text
import qualified Data.Attoparsec.Text as Atto
import Data.Either (lefts, rights)
import Data.HashMap.Lazy (HashMap)
import qualified Data.HashMap.Lazy as HashMap
import Data.Monoid ((<>))

--------------------------------------------------------------------------------
-- latin-ltx.el
--------------------------------------------------------------------------------

parseTex :: Parser [Translation]
parseTex = parseTexTranslation `sepBy1` skipGarbage

parseTexCode :: Parser Text
parseTexCode = do
    char '\"'
    result <- ingoreEscaped
    char '\"'
    return result
    where
        ingoreEscaped :: Parser Text
        ingoreEscaped = do
            next <- peekChar
            case next of
                Nothing -> return ""
                Just peeked -> case peeked of
                    '\"' -> return "" -- ends everything
                    '\\' -> do -- escape the next
                        char '\\'
                        escaped <- Atto.take 1
                        rest <- ingoreEscaped
                        return $ Text.singleton peeked <> escaped <> rest
                    others -> do
                        _ <- anyChar
                        rest <- ingoreEscaped
                        return $ Text.singleton others <> rest

parseTexGlyph :: Parser Text
parseTexGlyph = do
    glyph <- Atto.take 1
    if Text.unpack glyph == "\\"
        then do
            escaped <- Atto.take 1
            return $ glyph <> escaped
        else
            return glyph


parseTexTranslation :: Parser Translation
parseTexTranslation = do
    char '('
    code <- Text.unpack <$> parseTexCode
    skipSpaces
    char '?'
    glyph <- parseTexGlyph
    char ')'
    return $ Translation code [glyph]


--------------------------------------------------------------------------------
-- agda-input.el
--------------------------------------------------------------------------------

parseAgdaInput :: Parser [Translation]
parseAgdaInput = parseTranslation `sepBy1` skipGarbage

parseTranslation :: Parser Translation
parseTranslation = do
    char '('
    skipSpaces
    code <- fmap Text.unpack parseCode
    skipSpaces
    char '.'
    skipSpaces
    many' (char ',')
    char '('
    glyphs <- parseGlyphs
    char ')'
    char ')'
    return $ Translation code glyphs


parseCode :: Parser Text
parseCode = do
    char '\"'
    result <- takeTill ((==) '\"')
    char '\"'
    return result

parseGlyphs :: Parser [Text]
parseGlyphs = do
    skipSpaces
    fmap concat $ sepBy (choice
        [   do
                char '\"'
                result <- takeTill ((==) '\"')
                char '\"'
                return (Text.words result >>= Text.group)
        ,   do
                string "agda-input-to-string-list"
                return []

        ]) skipSpaces

--------------------------------------------------------------------------------
-- Trie
--------------------------------------------------------------------------------

parseTrie :: Parser Trie
parseTrie = do
    string "export default " <?> "header: export default "
    trie <- parseObject
    choice [string ";\n", string ";"]
    return trie
    -- where
parseCandidates :: Parser [Text]
parseCandidates = do
    string "["
    candidates <- parseCode `sepBy` char ','
    string "]"
    return candidates

parsePair :: Parser (Either [Text] (Text, Trie))
parsePair = do
    key <- parseCode
    string ":"
    if key == ">>"
        then Left <$> parseCandidates
        else do
            trie <- parseObject
            return $ Right (key, trie)

parseObject :: Parser Trie
parseObject = do
    string "{"
    pairs <- parsePair `sepBy1` char ','
    p <- peekChar
    string "}"
    return $ Node (HashMap.fromList (rights pairs)) (concat $ lefts pairs)
    where

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

skipSpaces :: Parser ()
skipSpaces = skipWhile (== ' ')

skipComment :: Parser ()
skipComment = do
    choice [string ";;", string ";"]
    skipWhile (\c -> c /= '\n')
    char '\n'
    return ()

skipGarbage :: Parser [()]
skipGarbage = many' $ choice [
        skipComment,
        void $ char '\n',
        void $ char '\t',
        void $ many1 (char ' ')
    ]