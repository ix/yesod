{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{- |
This module uses HXT to transverse an HTML document using CSS selectors.

The most important function here is 'findBySelector', it takes a CSS query and
a string containing the HTML to look into,
and it returns a list of the HTML fragments that matched the given query.

Only a subset of the CSS spec is currently supported:

 * By tag name: /table td a/

 * By class names: /.container .content/

 * By Id: /#oneId/

 * By attribute: /[hasIt]/, /[exact=match]/, /[contains*=text]/, /[starts^=with]/, /[ends$=with]/

 * Union: /a, span, p/

 * Immediate children: /div > p/

 * Get jiggy with it: /div[data-attr=yeah] > .mon, .foo.bar div, #oneThing/

-}

module Yesod.Test.TransversingCSS (
  findBySelector,
  findAttributeBySelector,
  HtmlLBS,
  Query,
  -- * For HXT hackers
  -- | These functions expose some low level details that you can blissfully ignore.
  parseQuery,
  runQuery,
  Selector(..),
  SelectorGroup(..)

  )
where

import Yesod.Test.CssQuery
import qualified Data.Text as T
import qualified Control.Applicative
import Text.XML
import Text.XML.Cursor
import qualified Data.ByteString.Lazy as L
import qualified Text.HTML.DOM as HD
import Text.Blaze.Html (toHtml)
import Text.Blaze.Html.Renderer.String (renderHtml)

type Query = T.Text
type HtmlLBS = L.ByteString

-- | Perform a css 'Query' on 'Html'. Returns Either
--
-- * Left: Query parse error.
--
-- * Right: List of matching Html fragments.
findBySelector :: HtmlLBS -> Query -> Either String [String]
findBySelector html query =
  map (renderHtml . toHtml . node) Control.Applicative.<$> findCursorsBySelector html query

-- | Perform a css 'Query' on 'Html'. Returns Either
--
-- * Left: Query parse error.
--
-- * Right: List of matching Cursors
findCursorsBySelector :: HtmlLBS -> Query -> Either String [Cursor]
findCursorsBySelector html query =
  runQuery (fromDocument $ HD.parseLBS html)
       Control.Applicative.<$> parseQuery query

-- | Perform a css 'Query' on 'Html'. Returns Either
--
-- * Left: Query parse error.
--
-- * Right: List of matching Cursors
--
-- @since 1.5.7
findAttributeBySelector :: HtmlLBS -> Query -> T.Text -> Either String [[T.Text]]
findAttributeBySelector html query attr =
  map (laxAttribute attr) Control.Applicative.<$> findCursorsBySelector html query


-- Run a compiled query on Html, returning a list of matching Html fragments.
runQuery :: Cursor -> [[SelectorGroup]] -> [Cursor]
runQuery html query = concatMap (runGroup html) query

runGroup :: Cursor -> [SelectorGroup] -> [Cursor]
runGroup c [] = [c]
runGroup c (DirectChildren s:gs) = concatMap (flip runGroup gs) $ c $/ selectors s
runGroup c (DeepChildren s:gs) = concatMap (flip runGroup gs) $ c $// selectors s

selectors :: [SelectorType] -> Cursor -> [Cursor]
selectors cs c
    | all (selectorType c) cs = [c]
    | otherwise = []

selectorType :: Cursor -> SelectorType -> Bool
selectorType c (SimpleSelector s) = selector c s
selectorType c (CompoundSelector s ps) = compound c s ps

compound :: Cursor -> Selector -> [PseudoSelector] -> Bool
compound c s ps = selector c s 
  && foldl (\accu -> (accu &&) . pseudoselector c s) True ps

selector :: Cursor -> Selector -> Bool
selector c (ById x) = not $ null $ attributeIs "id" x c
selector c (ByClass x) =
    case attribute "class" c of
        t:_ -> x `elem` T.words t
        [] -> False
selector c (ByTagName t) = not $ null $ element (Name t Nothing Nothing) c
selector c (ByAttrExists t) = not $ null $ hasAttribute (Name t Nothing Nothing) c
selector c (ByAttrEquals t v) = not $ null $ attributeIs (Name t Nothing Nothing) v c
selector c (ByAttrContains n v) =
    case attribute (Name n Nothing Nothing) c of
        t:_ -> v `T.isInfixOf` t
        [] -> False
selector c (ByAttrStarts n v) =
    case attribute (Name n Nothing Nothing) c of
        t:_ -> v `T.isPrefixOf` t
        [] -> False
selector c (ByAttrEnds n v) =
    case attribute (Name n Nothing Nothing) c of
        t:_ -> v `T.isSuffixOf` t
        [] -> False
selector _ Asterisk = True

pseudoselector :: Cursor -> Selector -> PseudoSelector -> Bool
pseudoselector c _ FirstChild = null $ precedingSibling c
pseudoselector c _ LastChild = null $ followingSibling c
pseudoselector c _ (NthChild anpb) = let i = index1 c in
  case anpb of
    Repetition 0 b -> i == b 
    Repetition a b | a <= 0 -> i <= b 
    Repetition a b -> i >= b && (i + b) `mod` a == 0
    Position p -> i == p
    Odd -> odd i
    Even -> even i


-- | Returns the index of the node at a cursor amongst its siblings, starting at 1.
index1 :: Cursor -> Int
index1 = (+ 1) . index 

-- | Returns the index of the node at a cursor amongst its siblings, starting at 0.
index :: Cursor -> Int
index = length . precedingSibling
