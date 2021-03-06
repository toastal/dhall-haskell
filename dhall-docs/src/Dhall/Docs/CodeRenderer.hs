{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

{-| Contains the logic to render the source code inside a HTML. It also provides
    context-sensitive features such as jump-to-definition.

    Rendering an expression consists on the following steps:

    * An 'Expr Src Import' with its parsed 'Text' is processed into
      a '[SourceCodeFragment]'
    * Each 'SourceCodeFragment' tells the 'renderSourceCodeFragment' how to
      render that function as HTML including the injected information through
      HTML data-attributes

    To render a Dhall file you should use 'renderCodeWithHyperLinks' which
    takes a 'Text' that was used to parse the 'Expr Src Import', and returns
    the generated 'Html ()' with the same structure (i.e. whitespaces)
    from the 'Text' argument.

    To render code-snippets (e.g. assertions from examples, type from source code)
    you should use 'renderCodeSnippet' which uses the output of @dhall format@
    as the 'Text' argument to call later 'renderCodeWithHyperLinks'
-}
module Dhall.Docs.CodeRenderer
    ( renderCodeWithHyperLinks
    , renderCodeSnippet
    , ExprType(..)
    ) where

import Data.Text           (Text)
import Data.Void           (Void)
import Dhall.Core
    ( Binding (..)
    , Expr (..)
    , File (..)
    , FilePrefix (..)
    , Import (..)
    , ImportHashed (..)
    , ImportType (..)
    , Scheme (..)
    , URL (..)
    , Var (..)
    )
import Dhall.Docs.Util
import Dhall.Src           (Src (..))
import Lucid
import Text.Megaparsec.Pos (SourcePos (..))

import qualified Data.Text                             as Text
import qualified Data.Text.Prettyprint.Doc             as Pretty
import qualified Data.Text.Prettyprint.Doc.Render.Text as Pretty.Text
import qualified Dhall.Context                         as Context
import qualified Dhall.Core                            as Core
import qualified Dhall.Parser
import qualified Dhall.Pretty
import qualified Lens.Family                           as Lens
import qualified Text.Megaparsec.Pos                   as SourcePos

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> import Dhall.Core (Directory (..))

-- | Get the source line and column from a 'SourcePos' as an 'Int'
getSourceLine, getSourceColumn :: SourcePos -> Int
getSourceLine = SourcePos.unPos . SourcePos.sourceLine
getSourceColumn = SourcePos.unPos . SourcePos.sourceColumn

-- | To make each variable unique we record the source position where it was
--   found.
data VarDecl = VarDecl Src Text

makeHtmlId :: VarDecl -> Text
makeHtmlId (VarDecl Src{srcStart} _) =
       "var"
    <> Text.pack (show $ getSourceLine srcStart) <> "-"
    <> Text.pack (show $ getSourceColumn srcStart)

-- | Available ways of rendering source code as HTML
data SourceCodeType
    -- | Relative and remote imports are rendered using an HTML anchor tag.
    --   Other imports are rendered as plain-text
    = ImportExpr Import

    -- | Used to render a variable declared in let-binding that is used in
    --   any expression
    | VariableUse VarDecl

    -- | Used to render the declaration of a variable. This is used to jump
    --   to that variable after clicking an 'VariableUse'
    | VariableDeclaration VarDecl

{-| The 'Expr Src Import' parsed from a 'Text' is split into a
    '[SourceCodeFragment]'.
-}
data SourceCodeFragment =
    SourceCodeFragment
        Src -- ^ The start and end position of this fragment
        SourceCodeType -- ^ The type of 'SourceCodeFragment' that will guide HTML rendering

-- | Returns all 'SourceCodeFragment's in lexicographic order i.e. in the same
--   order as in the source code.
fragments :: Expr Src Import -> [SourceCodeFragment]
fragments = go Context.empty
  where
    go context = \case
        -- The parsed text of the import is located in it's `Note` constructor
        Note src (Embed a) -> [SourceCodeFragment src $ ImportExpr a]

        Let (Binding
                (Just Src { srcEnd = srcEnd0 })
                variable
                (Just Src { srcStart = srcStart1 })
                annotation
                _
                value) expr' ->
            sourceCodeFragment : fromAnnotation ++ fromValue ++ fromExpr'
          where
            fromAnnotation = case annotation of
                Nothing -> []
                Just (_, e) -> go context e

            fromValue = go context value

            initialSourcePos = srcEnd0
            endSourcePos = srcStart1
            varSrc = Src {..}
              where
                srcStart = initialSourcePos
                srcText =
                    if Text.length variable == realLength then variable
                    -- the variable was quoted using backticks
                    else "`" <> variable <> "`"

                srcEnd = endSourcePos

                realLength = getSourceColumn srcEnd - getSourceColumn srcStart

            varDecl = VarDecl varSrc variable

            sourceCodeFragment = SourceCodeFragment varSrc (VariableDeclaration varDecl)

            fromExpr' = go (Context.insert variable varDecl context) expr'


        Note src (Var (V name index)) ->
            case Context.lookup name index context of
                Nothing -> []
                Just varDecl -> [SourceCodeFragment src $ VariableUse varDecl]

        e -> concatMap (go context) $ Lens.toListOf Core.subExpressions e


fileAsText :: File -> Text
fileAsText File{..} = foldr (\d acc -> acc <> "/" <> d) "" (Core.components directory)
    <> "/" <> file

renderSourceCodeFragment :: SourceCodeFragment -> Html ()
renderSourceCodeFragment (SourceCodeFragment Src{..} (ImportExpr import_)) =
    renderImport import_ srcText
  where
    {-  Given an 'Import', render the contents in an HTML element that will allow
        users to jump to another file or domain. The 'Text' argument is the contents
        inside the anchor tag

        Example:

        >>> :set -Wno-missing-fields
        >>> let file = File { directory = Directory [], file = ""}
        >>> let url = URL { scheme = HTTPS, authority = "google.com", query = Nothing, path = file}
        >>> let import_ = Import {importHashed = ImportHashed { importType = Remote url }}
        >>> renderImport import_ "link for google"
        <a href="https://google.com/" target="_blank">link for google</a>
    -}
    renderImport :: Import -> Text -> Html ()
    renderImport (Import {importHashed = ImportHashed { importType }}) =
        case importType of
            Remote URL {..} -> a_ [href_ href, target_ "_blank"] . toHtml
              where
                scheme_ = case scheme of
                    HTTP -> "http"
                    HTTPS -> "https"

                path_ = fileAsText path

                query_ = case query of
                    Nothing -> ""
                    Just d -> "?" <> d

                -- we don't include the headers here since we treat links to open a file
                -- in another tab
                href = scheme_ <> "://" <> authority <> path_ <> query_

            Local Here file -> a_ [href_ href] . toHtml
              where
                href = "." <> fileAsText file <> ".html"

            Local Parent file -> a_ [href_ href] . toHtml
              where
                href = ".." <> fileAsText file <> ".html"

            _ -> toHtml


renderSourceCodeFragment (SourceCodeFragment Src{..} (VariableDeclaration varDecl)) =
    span_ attributes $ toHtml srcText
  where
    attributes =
        [id_ $ makeHtmlId varDecl
        , class_ "variable-decl"
        , data_ "variable" $ makeHtmlId varDecl ]
renderSourceCodeFragment (SourceCodeFragment Src{..} (VariableUse varDecl)) =
    a_ attributes $ toHtml srcText
  where
    attributes =
        [ href_ $ "#" <> makeHtmlId varDecl
        , class_ "variable-use"
        , data_ "variable" $ makeHtmlId varDecl
        ]

-- | Given a Text and the parsed `Expr Src Import` from it, this will render the
--   the source code on HTML with jump-to-definition on URL imports. Use this
--   to render the source code with the same structure (whitespaces, comments,
--   language elements) as the source file
renderCodeWithHyperLinks :: Text -> Expr Src Import -> Html ()
renderCodeWithHyperLinks contents expr = pre_ $ go (1, 1) (Text.lines contents) imports
  where
    imports = fragments expr

    -- we keep the current line, column and consumed text as part of function argument
    go :: (Int, Int) -> [Text] -> [SourceCodeFragment] -> Html ()
    go _ textLines [] = mapM_ (\t -> toHtml t >> br_ []) textLines

    -- consume lines until we encounter the first 'SourceCodeFragment'
    go (currLineNumber, _) (currLine : restLines) scfs@((SourceCodeFragment Src {..} _) : _)
        | getSourceLine srcStart /= currLineNumber = do
            toHtml currLine
            br_ []
            go (currLineNumber + 1, 1) restLines scfs

    go (_, currCol) currentLines (scf@(SourceCodeFragment Src {..} _) : rest) = do
        let importStartLine = getSourceLine srcStart
        let importEndLine = getSourceLine srcEnd

        let importStartCol = getSourceColumn srcStart
        let importEndCol = getSourceColumn srcEnd

        let (importLines, suffixLines) = splitAt (importEndLine - importStartLine + 1) currentLines

        -- calls to `head` and `last` here should never fail since `importLines`
        -- have at least one element
        let (firstImportLine, lastImportLine) = (head importLines, last importLines)
        let prefixCols = Text.take (importStartCol - currCol) firstImportLine
        let suffixCols = Text.drop (importEndCol - currCol) lastImportLine

        -- render the prefix column
        toHtml prefixCols

        -- rendered element
        renderSourceCodeFragment scf

        -- add a newline if last line of import consumes the remaining line on
        -- the original text
        if Text.null suffixCols then br_ [] else return ()

        let suffix = if Text.null suffixCols then suffixLines else suffixCols : suffixLines

        -- move the cursor to next line if no characterse are remaining on the
        -- suffix cols, otherwise keep the last line and next char right after
        -- the import. This is done to handle properly several imports on the
        -- same line
        let nextPosition = if Text.null suffixCols then
                               (importEndLine + 1, 1)
                           else (importEndLine, importEndCol)

        go nextPosition suffix rest

-- | Internal utility to differentiate if a Dhall expr is a type annotation
--   or the whole file
data ExprType = TypeAnnotation | AssertionExample

-- | Renders an AST /fragment/ from the source file AST. Use this when you don't
--   have access to the 'Text' that was used to generate the AST.
--   The difference between this and 'renderCodeWithHyperLinks' is that
--   the extracted fragment's 'SourcePos's need to be re-generated to
--   render them in a better way; just adding whitespace at the beginning of the
--   first line won't render good results.
renderCodeSnippet :: Dhall.Pretty.CharacterSet -> ExprType -> Expr Void Import -> Html ()
renderCodeSnippet characterSet exprType expr = renderCodeWithHyperLinks formattedFile expr'
  where
    layout = case exprType of
        AssertionExample -> Dhall.Pretty.layout
        TypeAnnotation -> typeLayout

    formattedFile = Pretty.Text.renderStrict
        $ layout
        $ Dhall.Pretty.prettyCharacterSet characterSet (Core.denote expr)

    expr' = case Dhall.Parser.exprFromText "" formattedFile of
        Right e -> e
        Left _ -> fileAnIssue "A failure has occurred while parsing a formatted file"

    typeLayout = Pretty.removeTrailingWhitespace . Pretty.layoutSmart opts
      where
        -- this is done so the type of a dhall file fits in a single line
        -- its a safe value, since types in source codes are not that large
        opts = Pretty.defaultLayoutOptions
                { Pretty.layoutPageWidth =
                    Pretty.Unbounded
                }
