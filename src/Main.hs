{-# LANGUAGE OverloadedStrings #-}
module Main where

import              Types
import              Parser
import              Data.IntMap.Lazy (IntMap)
import qualified    Data.IntMap.Lazy as IntMap
import              Data.HashMap.Lazy (HashMap)
import qualified    Data.HashMap.Lazy as HashMap
import              Data.ByteString.Lazy (ByteString)
import qualified    Data.ByteString.Lazy as BS
import              Data.Text (Text)
import qualified    Data.Text as Text
import              Data.List (notElem, nub)
import              Data.Aeson
import              Data.Aeson.Types (Pair)
import              Data.Monoid ((<>))
import              Data.Attoparsec.Text

sanitizeGlyph :: Translation -> Translation
sanitizeGlyph (Translation code glyphs)
    = Translation code (map (Text.map escape) glyphs)
    where
        escape :: Char -> Char
        -- U+2028 line separator (HTML &#8232; · LSEP)
        escape '\8232' = '\n'
        -- U+2029 paragraph separator (HTML &#8233; · PSEP)
        escape '\8233' = '\n'
        escape others = others


main :: IO ()
main = do
    -- keymaps drawn from two different sources
    agdaInput <- readAndParse parseAgdaInput "agda-input.el"
    tex <- readAndParse parseTex "latin-ltx.el"
    alphaNumeric <- readAndParse parseExtension "alpha-numeric.ext"

    let sanitaized = map sanitizeGlyph (agdaInput ++ tex ++ alphaNumeric)
    let trie = growTrie sanitaized
    let lookupTable = growLookupTable sanitaized

    BS.writeFile "out/keymap.ts" (serialize trie)
    BS.writeFile "out/query.ts" (serialize (toJSONLookupTable lookupTable))
    BS.writeFile "out/keymap.json" (serializeJSON trie)
    BS.writeFile "out/query.json" (serializeJSON (toJSONLookupTable lookupTable))

-- reading ".el" files and parse them with the given parser
readAndParse :: Parser [Translation] -> String -> IO [Translation]
readAndParse parser path = do
    raw <- readFile $ "assets/" <> path
    case parseOnly parser (Text.pack raw) of
        Left err -> do
            print err
            return []
        Right val ->
            return val

test :: Parser [Translation] -> String -> IO ()
test parser path = do
    raw <- readFile $ "assets/" <> path <> ".el"
    parseTest parser (Text.pack raw)
    return ()

--------------------------------------------------------------------------------
-- Trie
--------------------------------------------------------------------------------

growTrie :: [Translation] -> Trie
growTrie = foldr insert emptyTrie
    where
        insert :: Translation -> Trie -> Trie
        insert (Translation [] glyphs) (Node entries candidates) = Node entries (nub (glyphs ++ candidates))
        insert (Translation (x:xs) glyphs) (Node entries candidates) = Node entries' candidates
            where
                entries' :: HashMap Text Trie
                entries' = case HashMap.lookup (Text.singleton x) entries of
                    Just trie -> HashMap.insert (Text.singleton x) (insert (Translation xs glyphs) trie) entries
                    Nothing -> HashMap.insert (Text.singleton x) (insert (Translation xs glyphs) emptyTrie) entries

        emptyTrie :: Trie
        emptyTrie = Node HashMap.empty []

serialize :: ToJSON a => a -> ByteString
serialize trie = "export default " <> encode trie <> ";"

serializeJSON :: ToJSON a => a -> ByteString
serializeJSON trie = encode trie

cardinality :: Trie -> Int
cardinality (Node entries candidates) = length candidates + sum (map cardinality (HashMap.elems entries))

elems :: Trie -> [Text]
elems (Node entries candidates) = nub $ concat (candidates : map elems (HashMap.elems entries))

--------------------------------------------------------------------------------
-- Trie
--------------------------------------------------------------------------------

fetchLegacyTrie :: IO Trie
fetchLegacyTrie = do
    raw <- BS.init . BS.init . BS.drop 15 <$> (BS.readFile "assets/legacy.ts")
    case (decode raw :: Maybe Trie) of
        Nothing -> error "failed"
        Just trie -> return trie

--------------------------------------------------------------------------------
-- Unicode => Input Sequence
--------------------------------------------------------------------------------

growLookupTable :: [Translation] -> LookupTable
growLookupTable xs = foldr insert IntMap.empty $ xs >>= toEntries
    where
        insert :: Entry -> LookupTable -> LookupTable
        insert (cp, codes) old = IntMap.insertWith (++) cp codes old

        toEntries :: Translation -> [Entry]
        toEntries (Translation code glyphs) = map (\g -> (toCodePoint g, [code])) glyphs

        toCodePoint :: Text -> Int
        toCodePoint x = head $ map fromEnum (Text.unpack x)

toJSONLookupTable :: LookupTable -> Value
toJSONLookupTable = object . map fromEntry . IntMap.toList
    where
        fromEntry :: Entry -> Pair
        fromEntry (cp, codes) = (Text.pack (show cp), toJSON codes)
