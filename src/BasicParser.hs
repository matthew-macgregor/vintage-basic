-- BasicParser.hs
-- Parses BASIC source code to produce abstract syntax.
-- Also used at runtime to input values.
-- Lyle Kopnicky

module BasicParser(statementListP) where

import Data.Char
import Text.ParserCombinators.Parsec
import Text.ParserCombinators.Parsec.Expr
import BasicLexCommon
import BasicSyntax
import BasicTokenizer

-- TODO: think about when to use 'try'

-- only first 2 chars and 1st digit of variable names are siginificant
-- should make this settable by option
varSignifLetters = 2 :: Int
varSignifDigits = 1 :: Int

type TokParser = GenParser (Tagged Token) ()

skipSpace :: TokParser ()
skipSpace = skipMany $ tokenP (==SpaceTok)

lineNumP :: TokParser Int
lineNumP =
    do s <- many1 (tokenP (charTokTest isDigit) <?> "") <?> "line number"
       return (read (map (getCharTokChar . getTaggedVal) s))

-- LITERALS

floatLitP :: TokParser Literal
floatLitP =
    do v <- floatP
       return (FloatLit v)

sgnP :: TokParser String
sgnP =
    do sgn <- tokenP (==PlusTok) <|> tokenP (==MinusTok)
       return (if (getTaggedVal sgn) == PlusTok then "" else "-")

floatP :: TokParser Float
floatP =
    do sgn <- option "" sgnP
       mant <- try float2P <|> float1P
       exp <- option "" expP
       skipSpace
       return (read (sgn++mant++exp))

expP :: TokParser String
expP =
    do tokenP (charTokTest (=='E'))
       esgn <- option "" sgnP
       i <- many1 (tokenP (charTokTest isDigit))
       return ("E"++esgn++(taggedCharToksToString i))

float1P :: TokParser String
float1P =
    do toks <- many1 (tokenP (charTokTest isDigit))
       return $ taggedCharToksToString toks

float2P :: TokParser String
float2P =
    do i <- many (tokenP (charTokTest isDigit))
       tokenP (charTokTest (=='.'))
       f <- many (tokenP (charTokTest isDigit))
       return ("0"++taggedCharToksToString i++"."++taggedCharToksToString f++"0")

stringLitP :: TokParser Literal
stringLitP =
    do tok <- tokenP isStringTok
       return (StringLit (getStringTokString (getTaggedVal tok)))

litP :: TokParser Literal
litP = floatLitP <|> stringLitP

-- VARIABLES

varBaseP :: TokParser String
varBaseP = do ls <- many1 (tokenP (charTokTest isAlpha))
              ds <- many (tokenP (charTokTest isDigit))
              return (taggedCharToksToString (take varSignifLetters ls
                      ++ take varSignifDigits ds))

floatVarP :: TokParser Var
floatVarP = do name <- varBaseP
               return (FloatVar name [])

intVarP :: TokParser Var
intVarP = do name <- varBaseP
             tokenP (==PercentTok)
             return (IntVar name [])

stringVarP :: TokParser Var
stringVarP = do name <- varBaseP
                tokenP (==DollarTok)
                return (StringVar name [])

-- Look for string and int vars first because of $ and % suffixes.
simpleVarP :: TokParser Var
simpleVarP = try stringVarP <|> try intVarP <|> floatVarP

arrP :: TokParser Var
arrP =
    do v <- simpleVarP
       xs <- argsP
       return (case v
                 of FloatVar name [] -> FloatVar name xs
                    IntVar name [] -> IntVar name xs
                    StringVar name [] -> StringVar name xs)

varP :: TokParser Var
varP = do v <- try arrP <|> simpleVarP
          skipSpace
          return v

-- EXPRESSIONS

litXP :: TokParser Expr
litXP =
    do v <- litP
       return (LitX v)

varXP :: TokParser Expr
varXP =
    do v <- varP
       return (VarX v)

argsP :: TokParser [Expr]
argsP =
    do tokenP (==LParenTok)
       xs <- sepBy exprP (tokenP (==CommaTok))
       tokenP (==RParenTok)
       return xs

parenXP :: TokParser Expr
parenXP =
    do tokenP (==LParenTok)
       x <- exprP
       tokenP (==RParenTok)
       return (ParenX x)

primXP :: TokParser Expr
primXP = parenXP <|> litXP <|> varXP

opTable :: OperatorTable (Tagged Token) () Expr
opTable =
    [[prefix MinusTok MinusX, prefix PlusTok id],
     [binary PowTok  (BinX PowOp) AssocRight],
     [binary MulTok  (BinX MulOp) AssocLeft, binary DivTok   (BinX DivOp) AssocLeft],
     [binary PlusTok (BinX AddOp) AssocLeft, binary MinusTok (BinX SubOp) AssocLeft],
     [binary EqTok   (BinX EqOp)  AssocLeft, binary NETok    (BinX NEOp)  AssocLeft,
      binary LTTok   (BinX LTOp)  AssocLeft, binary LETok    (BinX LEOp)  AssocLeft,
      binary GTTok   (BinX GTOp)  AssocLeft, binary GETok    (BinX GEOp)  AssocLeft],
     [prefix NotTok   NotX],
     [binary AndTok  (BinX AndOp) AssocLeft],
     [binary OrTok   (BinX OrOp)  AssocLeft]]

binary :: Token -> (Expr -> Expr -> Expr) -> Assoc -> Operator (Tagged Token) () Expr
binary tok fun assoc =
    Infix (do tokenP (==tok); return fun) assoc
prefix :: Token -> (Expr -> Expr) -> Operator (Tagged Token) () Expr
prefix tok fun =
    Prefix (do tokenP (==tok); return fun)

exprP :: TokParser Expr
exprP = buildExpressionParser opTable primXP

-- STATEMENTS

letSP :: TokParser Statement
letSP =
    do tokenP (==LetTok)
       v <- varP
       tokenP (==EqTok)
       x <- exprP
       return (LetS v x)

gotoSP :: TokParser Statement
gotoSP =
    do tokenP (==GoTok)
       tokenP (==ToTok)
       n <- lineNumP
       return (GotoS n)

gosubSP :: TokParser Statement
gosubSP =
    do tokenP (==GoTok)
       tokenP (==SubTok)
       n <- lineNumP
       return (GosubS n)

returnSP :: TokParser Statement
returnSP =
    do tokenP (==ReturnTok)
       return ReturnS

ifSP :: TokParser Statement
ifSP =
    do tokenP (==IfTok)
       x <- exprP
       tokenP (==ThenTok)
       target <- try ifSPGoto <|> statementListP
       return (IfS x target)

ifSPGoto :: TokParser [Tagged Statement]
ifSPGoto =
    do pos <- getPosition
       n <- lineNumP
       return [Tagged pos (GotoS n)]

forSP :: TokParser Statement
forSP =
    do tokenP (==ForTok)
       v <- simpleVarP
       tokenP (==EqTok)
       x1 <- exprP
       tokenP (==ToTok)
       x2 <- exprP
       x3 <- option (LitX (FloatLit 1)) (tokenP (==StepTok) >> exprP)
       return (ForS v x1 x2 x3)

-- handles a NEXT and an optional variable list
nextSP :: TokParser Statement
nextSP =
    do tokenP (==NextTok)
       vs <- sepBy simpleVarP (tokenP (==CommaTok))
       if length vs > 0
          then return (NextS (Just vs))
	  else return (NextS Nothing)

printSP :: TokParser Statement
printSP =
    do tokenP (==PrintTok)
       xs <- sepBy exprP (tokenP (==SemiTok))
       (tokenP (==SemiTok) >> return (PrintS xs False))
           <|> return (PrintS xs True)

inputSP :: TokParser Statement
inputSP =
    do tokenP (==InputTok)
       ps <- option Nothing inputPrompt
       vs <- sepBy1 varP (tokenP (==CommaTok))
       return (InputS ps vs)

inputPrompt :: TokParser (Maybe String)
inputPrompt =
    do (StringLit p) <- stringLitP
       tokenP (==SemiTok)
       return (Just p)

endSP :: TokParser Statement
endSP =
    do tokenP (==EndTok)
       return EndS

dimSP :: TokParser Statement
dimSP =
    do tokenP (==DimTok)
       arr <- arrP
       return (DimS arr)

remSP :: TokParser Statement
remSP =
    do tok <- tokenP isRemTok
       return (RemS (getRemTokString (getTaggedVal tok)))

statementP :: TokParser (Tagged Statement)
statementP = do pos <- getPosition
                st <- choice $ map try [printSP, inputSP, gotoSP, gosubSP, returnSP,
                                        ifSP, forSP, nextSP, endSP, dimSP, remSP, letSP]
                return (Tagged pos st)

statementListP :: TokParser [Tagged Statement]
statementListP = do many (tokenP (==ColonTok))
                    sl <- sepEndBy1 statementP (many1 (tokenP (==ColonTok)))
                    eof <?> "colon or end of line"
                    return sl                    

-- DATA STATEMENTS / INPUT BUFFER

-- We don't need to look for EOL characters, because these will only be
-- fed single lines.

-- readFloat :: String -> Maybe Float
-- readFloat s =
--     case parse floatP "" s
--          of (Right fv) -> Just fv
--             _ -> Nothing

-- nonCommaP :: Parser Char
-- nonCommaP = satisfy (/=',')

-- stringP :: Parser String
-- stringP =
--     do char '"'
--        s <- manyTill anyChar (char '"')
--        return s

-- trim :: String -> String
-- trim s = dropWhile (==' ') $ reverse $ dropWhile (==' ') $ reverse s

-- dataValP :: Parser String
-- dataValP =
--     do s <- stringP <|> many nonCommaP
--        return (trim s)

-- dataValsP :: Parser [String]
-- dataValsP = sepBy1 dataValP (char ',')
