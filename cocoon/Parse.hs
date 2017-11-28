{-
Copyrights (c) 2017. VMware, Inc. All right reserved. 
Copyrights (c) 2016. Samsung Electronics Ltd. All right reserved. 

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}

{-# LANGUAGE FlexibleContexts, RecordWildCards #-}

module Parse ( cocoonGrammar
             , cmdGrammar
             , cfgGrammar) where

import Control.Applicative hiding (many,optional,Const)
import Control.Monad
import Text.Parsec hiding ((<|>))
import Text.Parsec.Expr
import Text.Parsec.Language
import qualified Text.Parsec.Token as T
import Data.Maybe
import Data.Either
import Numeric

import Syntax
import Pos
import Util
import Builtins
import Name

reservedOpNames = [":", "?", "!", "|", "&", "==", "=", ":-", "%", "+", "-", ".", "->", "=>", "<=", "<=>", ">=", "<", ">", "!=", ">>", "<<", "#", "@", "\\"]
reservedNames = ["_",
                 "and",
                 "any",
                 "assume",
                 "bit",
                 "bool",
                 "check",
                 "default",
                 "drop",
                 "else",
                 "false",
                 "foreign",
                 "for",
                 "fork",
                 "function",
                 "if",
                 "in",
                 "int",
                 "key",
                 "match",
                 "sink",
                 "not",
                 "or",
                 "out",
                 "pkt",
                 "primary",
                 "procedure",
                 "put",
                 "delete",
                 "references",
                 "refine",
                 "send",
                 "source",
                 "state",
                 "string",
                 "table",
                 "true",
                 "typedef",
                 "unique",
                 "var",
                 "view",
                 "the"]


ccnDef = emptyDef { T.commentStart      = "/*"
                  , T.commentEnd        = "*/"
                  , T.commentLine       = "//"
                  , T.nestedComments    = True
                  , T.identStart        = letter <|> char '_' 
                  , T.identLetter       = alphaNum <|> char '_'
                  , T.reservedOpNames   = reservedOpNames
                  , T.reservedNames     = reservedNames
                  , T.opLetter          = oneOf "!?:%*-+./=|<>"
                  , T.caseSensitive     = True}

ccnLCDef = ccnDef{T.identStart = lower <|> char '_'}
ccnUCDef = ccnDef{T.identStart = upper}

lexer   = T.makeTokenParser ccnDef
lcLexer = T.makeTokenParser ccnLCDef
ucLexer = T.makeTokenParser ccnUCDef

reservedOp   = T.reservedOp lexer
reserved     = T.reserved lexer
identifier   = T.identifier lexer
lcIdentifier = T.identifier lcLexer
ucIdentifier = T.identifier ucLexer
--semiSep    = T.semiSep lexer
--semiSep1   = T.semiSep1 lexer
colon        = T.colon lexer
commaSep     = T.commaSep lexer
commaSep1    = T.commaSep1 lexer
symbol       = T.symbol lexer
semi         = T.semi lexer
comma        = T.comma lexer
braces       = T.braces lexer
parens       = T.parens lexer
angles       = T.angles lexer
brackets     = T.brackets lexer
natural      = T.natural lexer
decimal      = T.decimal lexer
--integer    = T.integer lexer
whiteSpace   = T.whiteSpace lexer
lexeme       = T.lexeme lexer
dot          = T.dot lexer
stringLit    = T.stringLiteral lexer
--charLit    = T.charLiteral lexer

consIdent   = ucIdentifier
relIdent    = ucIdentifier
switchIdent = ucIdentifier
portIdent   = ucIdentifier
taskIdent   = ucIdentifier
varIdent    = lcIdentifier
funcIdent   = lcIdentifier

removeTabs = do s <- getInput
                let s' = map (\c -> if c == '\t' then ' ' else c ) s 
                setInput s'          

withPos x = (\s a e -> atPos a (s,e)) <$> getPosition <*> x <*> getPosition


data SpecItem = SpType         TypeDef
              | SpState        Field
              | SpRelation     Relation
              | SpAssume       Assume
              | SpFunc         Function
              | SpSwitch       Switch
              | SpPort         SwitchPort
              | SpTask         Task

cocoonGrammar = removeTabs *> ((optional whiteSpace) *> spec <* eof)
cmdGrammar = removeTabs *> ((optional whiteSpace) *> cmd <* eof)
cfgGrammar = removeTabs *> ((optional whiteSpace) *> (many relation) <* eof)

cmd =  (Left  <$ reservedOp ":" <*> many1 identifier)
   <|> (Right <$> expr)

spec = withPos $ mkRefine [] <$> (many decl)

--spec = (\r rs -> r:rs) <$> (withPos $ mkRefine [] <$> (many decl)) <*> (many refine)

mkRefine :: [String] -> [SpecItem] -> Refine
mkRefine targets items = Refine nopos targets types state funcs relations assumes switches ports tasks
    where relations = mapMaybe (\i -> case i of 
                                           SpRelation r -> Just r
                                           _            -> Nothing) items
          types = mapMaybe (\i -> case i of 
                                       SpType t -> Just t
                                       _        -> Nothing) items 
                  ++
                  map (\Relation{..} -> TypeDef relPos relName $ Just $ TStruct relPos 
                                                $ [Constructor relPos relName relArgs]) relations
          state = mapMaybe (\i -> case i of 
                                       SpState s -> Just s
                                       _         -> Nothing) items
          funcs = mapMaybe (\i -> case i of 
                                       SpFunc f -> Just f
                                       _        -> Nothing) items
          switches = mapMaybe (\i -> case i of 
                                          SpSwitch s -> Just s
                                          _          -> Nothing) items
          ports = mapMaybe (\i -> case i of 
                                       SpPort p -> Just p
                                       _        -> Nothing) items
          assumes = mapMaybe (\i -> case i of 
                                       SpAssume a -> Just a
                                       _          -> Nothing) items
          tasks = mapMaybe (\i -> case i of 
                                       SpTask t -> Just t
                                       _        -> Nothing) items

{-
refine = withPos $ mkRefine <$  reserved "refine" 
                            <*> (commaSep roleIdent)
                            <*> (braces $ many decl)
-}

decl =  (SpType         <$> typeDef)
    <|> (SpRelation     <$> relation)
    <|> (SpState        <$> stateVar)
    <|> (SpFunc         <$> func)
    <|> (SpFunc         <$> proc)
    <|> (SpSwitch       <$> switch)
    <|> (SpPort         <$> port)
    <|> (SpAssume       <$> assume)
    <|> (SpTask         <$> task)

typeDef = withPos $ (TypeDef nopos) <$ reserved "typedef" <*> identifier <*> (optionMaybe $ reservedOp "=" *> typeSpec)

stateVar = withPos $ reserved "state" *> arg

func = withPos $ Function nopos [] <$> (True <$ reserved "function")
                                   <*> funcIdent
                                   <*> (parens $ commaSep arg) 
                                   <*> (colon *> typeSpecSimple)
                                   <*> (optionMaybe $ reservedOp "=" *> expr)

fannot = withPos $
           ((try $ lookAhead $ reservedOp "#" *> symbol "controller") *> reservedOp "#" *>
            (AnnotController nopos <$ symbol "controller"))

proc = withPos $ Function nopos <$> many fannot
                                <*> (False <$ reserved "procedure") <*> funcIdent
                                <*> (parens $ commaSep arg) 
                                <*> (colon *> (typeSpecSimple <|> (withPos $ tSink <$ reserved "sink")))
                                <*> (Just <$ reservedOp "=" <*> expr)

switch = withPos $ Switch nopos <$ symbol "switch" <*> switchIdent <*> (brackets relIdent)

port = withPos $ SwitchPort nopos <$ symbol "port" <*> portIdent <*> (brackets relIdent) <*>
                                     (symbol "(" *> option False (True <$ reserved "source")) <*> funcIdent <*>
                                     (comma *> ( (Nothing <$ reserved "sink")
                                              <|>(Just <$> funcIdent))) <* symbol ")"

task = withPos $ Task nopos <$ symbol "task" <*> taskIdent <*> (brackets relIdent) <*> (parens funcIdent) <*> (reservedOp "@" *> duration)

duration = Duration <$> parseDec <*> ((Millisecond <$ (try $ symbol "ms")) <|> (Second <$ (try $ symbol "s")))

relation = do withPos $ do mutable <- (True <$ ((try $ lookAhead $ reserved "state" *> reserved "table") *> (reserved "state" *> reserved "table")))
                                      <|>
                                      (False <$ reserved "table")
                           n <- relIdent
                           (as, cs) <- liftM partitionEithers $ parens $ commaSep argOrConstraint
                           return $ Relation nopos mutable n as cs Nothing
                    <|> do reserved "view" 
                           n <- relIdent
                           (as, cs) <- liftM partitionEithers $ parens $ commaSep argOrConstraint
                           rs <- many1 $ withPos $ do 
                                         try $ lookAhead $ relIdent *> (parens $ commaSep rexpr) *> reservedOp ":-"
                                         rn <- relIdent
                                         when (rn /= n) $ fail $ "Only rules for relation \"" ++ n ++ "\" can be defined here"
                                         rargs <- parens $ commaSep rexpr
                                         reservedOp ":-"
                                         rhs <- commaSep rexpr
                                         return $ Rule nopos rargs rhs
                           return $ Relation nopos False n as cs $ Just rs

argOrConstraint =  (Right <$> constraint)
               <|> (Left  <$> arg)

constraint = withPos $  (PrimaryKey nopos <$ reserved "primary" <*> (reserved "key" *> (parens $ commaSep fexpr)))
                    <|> (ForeignKey nopos <$ reserved "foreign" <*> (reserved "key" *> (parens $ commaSep fexpr)) 
                                          <*> (reserved "references" *> relIdent) <*> (parens $ commaSep fexpr))
                    <|> (Unique     nopos <$ reserved "unique" <*> (parens $ commaSep fexpr))
                    <|> (Check      nopos <$ reserved "check" <*> expr)

assume = withPos $ Assume nopos <$ reserved "assume" <*> (option [] $ parens $ commaSep arg) <*> expr

{-
node = withPos $ Node nopos <$> ((NodeSwitch <$ reserved "switch") <|> (NodeHost <$ reserved "host"))
                            <*> identifier 
                            <*> (parens $ commaSep1 $ parens $ (,) <$> roleIdent <* comma <*> roleIdent)
-}

arg = withPos $ (Field nopos) <$> varIdent <*> (colon *> typeSpecSimple)

typeSpec = withPos $ 
            arrType
        <|> bitType 
        <|> intType
        <|> stringType
        <|> boolType 
        <|> structType 
        <|> userType 
        <|> tupleType
        <|> lambdaType
        
typeSpecSimple = withPos $ 
                  arrType
              <|> bitType 
              <|> intType
              <|> stringType
              <|> boolType 
              <|> tupleType
              <|> userType 
              <|> lambdaType

bitType    = TBit    nopos <$ reserved "bit" <*> (fromIntegral <$> angles decimal)
intType    = TInt    nopos <$ reserved "int"
stringType = TString nopos <$ reserved "string"
boolType   = TBool   nopos <$ reserved "bool"
userType   = TUser   nopos <$> identifier
arrType    = brackets $ TArray nopos <$> typeSpecSimple <* semi <*> (fromIntegral <$> decimal)
structType = TStruct nopos <$ isstruct <*> sepBy1 constructor (reservedOp "|") 
    where isstruct = try $ lookAhead $ consIdent *> (symbol "{" <|> symbol "|")
tupleType  = (\fs -> case fs of
                          [f] -> f
                          _   -> TTuple nopos fs)
             <$> (parens $ commaSep typeSpecSimple)
lambdaType = TLambda nopos <$  (reserved "function")
                           <*> (parens $ commaSep arg) 
                           <*> (colon *> typeSpecSimple)

constructor = withPos $ Constructor nopos <$> consIdent <*> (option [] $ braces $ commaSep arg)

expr =  buildExpressionParser etable term
    <?> "expression"

term  =  elhs
     <|> (withPos $ eTuple <$> (parens $ commaSep expr))
     <|> braces expr
     <|> term'
term' = withPos $
         eapply
     <|> eput
     <|> edelete
     <|> ebuiltin
     <|> eloc
     <|> erelpred
     <|> estruct
     <|> eint
     <|> ebool
     <|> estring
     <|> epacket
     <|> evar
     <|> ematch
     <|> edrop
     <|> eite
     <|> esend
     <|> evardcl
     <|> efork
     <|> efor
     <|> ewith
     <|> eany
     <|> elambda
     <|> eapplambda

elambda = eLambda <$ reservedOp "\\" <*> (parens $ commaSep arg) 
                                     <*> (colon *> typeSpecSimple)
                                     <*> (reservedOp "=" *> expr) 

eapplambda = eApplyLambda <$ reserved "eval" <*> (parens expr) <*> (parens $ commaSep expr)

eapply = eApply <$ isapply <*> funcIdent <*> (parens $ commaSep expr)
    where isapply = try $ lookAhead $ do 
                        f <- funcIdent
                        when (elem f (map name builtins)) parserZero
                        symbol "("
ebuiltin = eBuiltin <$ isbuiltin <*> funcIdent <*> (parens $ commaSep expr)
    where isbuiltin = try $ lookAhead $ do 
                        f <- funcIdent
                        when (notElem f (map name builtins)) parserZero
                        symbol "("

eloc = eLocation <$ isloc <*> portIdent <*> (brackets expr) <*> (reservedOp "." *> ((DirIn <$ reserved "in") <|> (DirOut <$ reserved "out"))) 
    where isloc = try $ lookAhead $ portIdent *> (brackets expr)
ebool = eBool <$> ((True <$ reserved "true") <|> (False <$ reserved "false"))
epacket = ePacket <$ reserved "pkt"
evar = eVar <$> varIdent

ematch = eMatch <$ reserved "match" <*> parens expr
               <*> (braces $ (commaSep1 $ (,) <$> pattern <* reservedOp "->" <*> expr))
pattern = withPos $ 
          eTuple   <$> (parens $ commaSep pattern)
      <|> eVarDecl <$> varIdent
      <|> epholder
      <|> eStruct  <$> consIdent <*> (option [] $ braces $ commaSep pattern)

lhs = withPos $ 
          eTuple <$> (parens $ commaSep lhs)
      <|> fexpr
      <|> evardcl
      <|> epholder
      <|> eStruct <$> consIdent <*> (option [] $ braces $ commaSep lhs)
elhs = islhs *> lhs
    where islhs = try $ lookAhead $ lhs *> reservedOp "="

erelpred = isrelpred *> (eRelPred <$> relIdent <*> (parens $ commaSep relarg))
    where isrelpred = try $ lookAhead $ relIdent *> symbol "("
relarg = withPos $ 
          eTuple <$> (parens $ commaSep relarg)
      <|> evar
      <|> epholder
      <|> eStruct <$> consIdent <*> (option [] $ braces $ commaSep relarg)

--eint  = Int <$> (fromIntegral <$> decimal)
eint  = lexeme eint'
estring = eString <$> stringLit
estruct = eStruct <$> consIdent <*> (option [] $ braces $ commaSep expr)

eint'   = (lookAhead $ char '\'' <|> digit) *> (do w <- width
                                                   v <- sradval
                                                   mkLit w v)

edrop   = eDrop    <$ reserved "drop"
esend   = eSend    <$ reserved "send" <*> expr
eite    = eITE     <$ reserved "if" <*> term <*> term <*> (optionMaybe $ reserved "else" *> term)
evardcl = eVarDecl <$ reserved "var" <*> varIdent
efork   = eFork    <$ reserved "fork" 
                   <*> (symbol "(" *> varIdent)
                   <*> (reserved "in" *> relIdent) 
                   <*> ((option eTrue (reservedOp "|" *> expr)) <* symbol ")")
                   <*> term
efor    = eFor     <$ reserved "for" 
                   <*> (symbol "(" *> varIdent)
                   <*> (reserved "in" *> relIdent) 
                   <*> ((option eTrue (reservedOp "|" *> expr)) <* symbol ")")
                   <*> term
ewith   = eWith    <$ reserved "the" 
                   <*> (symbol "(" *> varIdent)
                   <*> (reserved "in" *> relIdent) 
                   <*> ((option eTrue (reservedOp "|" *> expr)) <* symbol ")")
                   <*> term
                   <*> (optionMaybe $ reserved "default" *> term)

eany    = eAny <$ reserved "any" 
               <*> (symbol "(" *> varIdent)
               <*> (reserved "in" *> relIdent) 
               <*> ((option eTrue (reservedOp "|" *> expr)) <* symbol ")")
               <*> term
               <*> (optionMaybe $ reserved "default" *> term)
eput    = ePut <$ isput <*> (relIdent <* dot <* reserved "put") <*> (parens expr)
               where isput = try $ lookAhead $ relIdent <* dot <* reserved "put"
edelete = eDelete <$ isdel <*> (relIdent <* dot <* reserved "delete") <*> (parens lambda)
                  where isdel = try $ lookAhead $ relIdent <* dot <* reserved "delete"
epholder = ePHolder <$ reserved "_"

width = optionMaybe (try $ ((fmap fromIntegral parseDec) <* (lookAhead $ char '\'')))
sradval =  ((try $ string "'b") *> parseBin)
       <|> ((try $ string "'o") *> parseOct)
       <|> ((try $ string "'d") *> parseDec)
       <|> ((try $ string "'h") *> parseHex)
       <|> parseDec
parseBin :: Stream s m Char => ParsecT s u m Integer
parseBin = readBin <$> (many1 $ (char '0') <|> (char '1'))
parseOct :: Stream s m Char => ParsecT s u m Integer
parseOct = (fst . head . readOct) <$> many1 octDigit
parseDec :: Stream s m Char => ParsecT s u m Integer
parseDec = (fst . head . readDec) <$> many1 digit
--parseSDec = (\m v -> m * v)
--            <$> (option 1 ((-1) <$ reservedOp "-"))
--            <*> ((fst . head . readDec) <$> many1 digit)
parseHex :: Stream s m Char => ParsecT s u m Integer
parseHex = (fst . head . readHex) <$> many1 hexDigit

mkLit :: Maybe Int -> Integer -> ParsecT s u m Expr
mkLit Nothing  v                       = return $ eInt v
mkLit (Just w) v | w == 0              = fail "Unsigned literals must have width >0"
                 | msb v < w           = return $ eBit w v
                 | otherwise           = fail "Value exceeds specified width"

etable = [[postf $ choice [postSlice, postApply, postBuiltin, postField, postType]]
         ,[pref  $ choice [prefix "not" Not]]
         ,[binary "%" Mod AssocLeft]
         ,[binary "+" Plus AssocLeft,
           binary "-" Minus AssocLeft]
         ,[binary ">>" ShiftR AssocLeft,
           binary "<<" ShiftL AssocLeft]
         ,[binary "++" Concat AssocLeft]
         ,[binary "==" Eq  AssocLeft,          
           binary "!=" Neq AssocLeft,          
           binary "<"  Lt  AssocNone, 
           binary "<=" Lte AssocNone, 
           binary ">"  Gt  AssocNone, 
           binary ">=" Gte AssocNone]
         ,[binary "&" BAnd AssocLeft]
         ,[binary "|" BOr AssocLeft]
         ,[binary "and" And AssocLeft]
         ,[binary "or" Or AssocLeft]
         ,[binary "=>" Impl AssocLeft]
         ,[assign AssocNone]
         ,[sbinary ";" ESeq AssocRight]
         ,[sbinary "|" EPar AssocRight]
         ]

pref  p = Prefix  . chainl1 p $ return       (.)
postf p = Postfix . chainl1 p $ return (flip (.))
postField = (\f end e -> E $ EField (fst $ pos e, end) e f) <$> field <*> getPosition
postApply = (\(f, args) end e -> E $ EApply (fst $ pos e, end) f (e:args)) <$> dotcall <*> getPosition
postBuiltin = (\(f, args) end e -> E $ EBuiltin (fst $ pos e, end) f (e:args)) <$> dotbuiltin <*> getPosition
postType = (\t end e -> E $ ETyped (fst $ pos e, end) e t) <$> etype <*> getPosition
postSlice  = try $ (\(h,l) end e -> E $ ESlice (fst $ pos e, end) e h l) <$> slice <*> getPosition
slice = brackets $ (\h l -> (fromInteger h, fromInteger l)) <$> natural <*> (colon *> natural)

field = dot *> varIdent
dotcall = (,) <$ isapply <*> (dot *> funcIdent) <*> (parens $ commaSep expr)
    where isapply = try $ lookAhead $ do 
                        _ <- dot 
                        f <- funcIdent
                        when (elem f (map name builtins)) parserZero
                        symbol "("

dotbuiltin = (,) <$ isbuiltin <*> (dot *> funcIdent) <*> (parens $ commaSep expr)
    where isbuiltin = try $ lookAhead $ do 
                        _ <- dot 
                        f <- funcIdent
                        when (notElem f (map name builtins)) parserZero
                        symbol "("

etype = reservedOp ":" *> typeSpecSimple

prefix n fun = (\start e -> E $ EUnOp (start, snd $ pos e) fun e) <$> getPosition <* reservedOp n
binary n fun  = Infix $ (\le re -> E $ EBinOp (fst $ pos le, snd $ pos re) fun le re) <$ reservedOp n
sbinary n fun = Infix $ (\l  r  -> E $ fun (fst $ pos l, snd $ pos r) l r) <$ reservedOp n

assign = Infix $ (\l r  -> E $ ESet (fst $ pos l, snd $ pos r) l r) <$ reservedOp "="

{- lambda-expression; currently only allowed in .delete statements -}
lambda =  buildExpressionParser etable lamterm
      <?> "lambda"

lamterm  =  eanon
        <|> (withPos $ eTuple <$> (parens $ commaSep lambda))
        <|> braces lambda
        <|> term'

eanon = withPos $ eAnon <$ reserved "?"

{- F-expression (variable of field name) -}
fexpr =  buildExpressionParser fetable fterm
    <?> "column or field name"

fterm  =  withPos $ evar

fetable = [[postf postField]]


{- expression allowed in a Datalog rule -}

rexpr =  buildExpressionParser retable rterm
    <?> "simple expression"

rterm  = withPos $
         erelpred
     <|> estruct
     <|> eint
     <|> ebool
     <|> estring
     <|> evar

retable = [[postf $ choice [postSlice, postType]]
         ,[pref  $ choice [prefix "not" Not]]
         ,[binary "%" Mod AssocLeft]
         ,[binary "+" Plus AssocLeft,
           binary "-" Minus AssocLeft]
         ,[binary ">>" ShiftR AssocLeft,
           binary "<<" ShiftL AssocLeft]
         ,[binary "++" Concat AssocLeft]
         ,[binary "==" Eq  AssocLeft,          
           binary "!=" Neq AssocLeft,          
           binary "<"  Lt  AssocNone, 
           binary "<=" Lte AssocNone, 
           binary ">"  Gt  AssocNone, 
           binary ">=" Gte AssocNone]
         ,[binary "&" BAnd AssocLeft]
         ,[binary "|" BOr AssocLeft]
         ,[binary "and" And AssocLeft]
         ,[binary "or" Or AssocLeft]
         ,[binary "=>" Impl AssocLeft]
         ]
