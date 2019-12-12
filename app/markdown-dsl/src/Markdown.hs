{-# LANGUAGE OverloadedStrings #-}

module Markdown where

import           Data.List              (intersperse)
import           Data.List.NonEmpty     (NonEmpty ((:|)))
import qualified Data.List.NonEmpty     as NE
import           Data.Text              (Text)
import qualified Data.Text              as T
import qualified Data.Text.Lazy         as LT
import           Data.Tree              (Forest)
import qualified Data.Tree              as Tree
import qualified HTMLEntities.Builder   as HEB

import           Data.Text.Lazy.Builder (toLazyText)


surround :: (Monoid a) => [a] -> a -> a
surround brackets = mconcat . (`intersperse` brackets)


surround2 :: Text -> Text -> Text
surround2 endcap = surround $ replicate 2 endcap


italic :: Text -> Text
italic = surround2 "*"


bold :: Text -> Text
bold = surround2 "**"


quote :: Text -> Text
quote = surround2 "\""


codeInline :: Text -> Text
codeInline = surround2 "`"


sup :: Text -> Text
sup = tagElement "sup"


parens :: Text -> Text
parens = surround ["(", ")"]


bracket :: Text -> Text
bracket = surround ["[", "]"]


angleBracket :: Text -> Text
angleBracket = surround ["<", ">"]


tagElement :: Text -> Text -> Text
tagElement tag_name =
  surround [opening_tag, closing_tag]
  where
    opening_tag = angleBracket tag_name
    closing_tag = angleBracket $ "/" <> tag_name


tagElementMultiline :: Text -> [Text] -> [Text]
tagElementMultiline tag_name content =
  [opening_tag] ++ content ++ [closing_tag]
  where
    opening_tag = angleBracket tag_name
    closing_tag = angleBracket $ "/" <> tag_name


supTitle :: Text -> Text -> Text
supTitle title = surround brackets
  where
    brackets = [
        "<sup title=\"" <> escaped_title <> "\">"
      , "</sup>"
      ]
    escaped_title = LT.toStrict $ toLazyText $ HEB.text title


heading :: Int -> Text -> Text
heading level title = T.unwords [
    mconcat $ replicate level "#"
  , title
  ]


link :: Text -> Text -> Text
link label url = bracket label <> parens url


image :: Text -> Text -> Text
image tooltip url = "!" <> link tooltip url


delimitColumns :: [Text] -> Text
delimitColumns cols = T.concat padded_cols
  where
    cols_temp = ["|"] <> intersperse "|" cols <> ["|"]
    padded_cols = intersperse " " cols_temp


table :: [Text] -> [[Text]] -> NonEmpty Text
table header_cols data_rows = NE.map delimitColumns all_table_rows
  where
    header_line = replicate (length header_cols) "---"
    all_table_rows = header_cols :| header_line : data_rows


bulletize :: Int -> NonEmpty Text -> NonEmpty Text
bulletize depth (x :| xs) =
  (first_line_indentation <> "* " <> x) :| map (content_indentation <>) xs
  where
    first_line_depth = 4 * depth
    first_line_indentation = mconcat $ replicate first_line_depth " "

    content_depth = first_line_depth + 2
    content_indentation = mconcat $ replicate content_depth " "


codeBlock :: NonEmpty Text -> NonEmpty Text
codeBlock code_lines = pure "```" <> code_lines <> pure "```"


codeBlockFromList :: [Text] -> NonEmpty Text
codeBlockFromList code_lines = "```" :| code_lines ++ ["```"]


-- | Terminates words with some punctuation
terminate :: Text -> [Text] -> Text
terminate terminator = (<> terminator) . T.unwords


-- | Adds a period at the end of a list of words.
sentence ::  [Text] -> Text
sentence = terminate "."


-- | Adds a colon at the end of a list of words.
colonize ::  [Text] -> Text
colonize = terminate ":"


-- | Adds a comma at the end of a list of words.
commaize ::  [Text] -> Text
commaize = terminate ","


-- | Note that the empty lines padding the markdown
-- inside the html tags are necessary, *as well as*
-- the trailing blank line *after* the closing html tag.
detailsExpander :: Text -> [Text] -> [Text]
detailsExpander heading details = x ++ [""]
  where
  x = tagElementMultiline "details" $ tagElementMultiline "summary" [heading] <> ([""] ++ details ++ [""])


-- | Inserts blank lines between each element
paragraphs :: [Text] -> Text
paragraphs = T.unlines . intersperse ""


bulletTree :: Forest (NonEmpty Text) -> Text
bulletTree = T.unlines . concatMap (NE.toList . uncurry bulletize) . flattenWithDepth 0


-- | Typically should call this with 0 as the first argument
flattenWithDepth :: Int -> Forest a -> [(Int, a)]
flattenWithDepth depth = concatMap go
  where
    go t = (depth, Tree.rootLabel t) : flattenWithDepth (depth + 1) (Tree.subForest t)
