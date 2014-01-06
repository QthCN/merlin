(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1996 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* $Id: lexer.mll 12511 2012-05-30 13:29:48Z lefessan $ *)

(* The lexer definition *)

{
open Lexing
open Std
open Misc
open Raw_parser

type keywords = (string, Raw_parser.token) Hashtbl.t

type error =
  | Illegal_character of char
  | Illegal_escape of string
  | Unterminated_comment of Location.t
  | Unterminated_string
  | Unterminated_string_in_comment of Location.t
  | Keyword_as_label of string
  | Literal_overflow of string

(* Monad in which the lexer evaluates *)
type 'a result =
  | Return of 'a
  | Refill of (unit -> 'a result)
  | Error of error * Location.t

let return a             = Return a
let refill_handler k state lexbuf arg = Refill (fun () -> k state lexbuf arg)
let refill_handler' k lexbuf arg = Refill (fun () -> k lexbuf arg)

let error e l            = Error (e,l)

let rec bind (m : 'a result) (f : 'a -> 'b result) : 'b result =
  match m with
  | Return a -> f a
  | Refill u ->
    Refill (fun () -> bind (u ()) f)
  | Error _ as e -> e

type state = {
  keywords: keywords;
  buffer: Buffer.t;
  mutable string_start_loc: Location.t;
  mutable comment_start_loc: Location.t list;
}

let catch m f = match m with
  | Error (e,l) -> f e l
  | r -> r

let (>>=) = bind

(* The table of keywords *)
let keyword_table : keywords =
  create_hashtable 149 [
    "and", AND;
    "as", AS;
    "assert", ASSERT;
    "begin", BEGIN;
    "class", CLASS;
    "constraint", CONSTRAINT;
    "do", DO;
    "done", DONE;
    "downto", DOWNTO;
    "else", ELSE;
    "end", END;
    "exception", EXCEPTION;
    "external", EXTERNAL;
    "false", FALSE;
    "for", FOR;
    "fun", FUN;
    "function", FUNCTION;
    "functor", FUNCTOR;
    "if", IF;
    "in", IN;
    "include", INCLUDE;
    "inherit", INHERIT;
    "initializer", INITIALIZER;
    "lazy", LAZY;
    "let", LET;
    "match", MATCH;
    "method", METHOD;
    "module", MODULE;
    "mutable", MUTABLE;
    "new", NEW;
    "object", OBJECT;
    "of", OF;
    "open", OPEN;
    "or", OR;
    (*"parser", PARSER; *)
    "private", PRIVATE;
    "rec", REC;
    "sig", SIG;
    "struct", STRUCT;
    "then", THEN;
    "to", TO;
    "true", TRUE;
    "try", TRY;
    "type", TYPE;
    "val", VAL;
    "virtual", VIRTUAL;
    "when", WHEN;
    "while", WHILE;
    "with", WITH;

    "mod", INFIXOP3("mod");
    "land", INFIXOP3("land");
    "lor", INFIXOP3("lor");
    "lxor", INFIXOP3("lxor");
    "lsl", INFIXOP4("lsl");
    "lsr", INFIXOP4("lsr");
    "asr", INFIXOP4("asr");
  ]

let keywords l = create_hashtable 11 l

(* To store the position of the beginning of a string and comment *)
let in_comment state = state.comment_start_loc <> []
let in_string state = state.string_start_loc != Location.none

(* To translate escape sequences *)

let char_for_backslash = function
  | 'n' -> '\010'
  | 'r' -> '\013'
  | 'b' -> '\008'
  | 't' -> '\009'
  | c   -> c

let char_for_decimal_code state lexbuf i =
  let c = 100 * (Char.code(Lexing.lexeme_char lexbuf i) - 48) +
           10 * (Char.code(Lexing.lexeme_char lexbuf (i+1)) - 48) +
                (Char.code(Lexing.lexeme_char lexbuf (i+2)) - 48) in
  if (c < 0 || c > 255) then
    if in_comment state
    then return 'x'
    else error (Illegal_escape (Lexing.lexeme lexbuf)) (Location.curr lexbuf)
  else return (Char.chr c)

let char_for_hexadecimal_code lexbuf i =
  let d1 = Char.code (Lexing.lexeme_char lexbuf i) in
  let val1 = if d1 >= 97 then d1 - 87
             else if d1 >= 65 then d1 - 55
             else d1 - 48
  in
  let d2 = Char.code (Lexing.lexeme_char lexbuf (i+1)) in
  let val2 = if d2 >= 97 then d2 - 87
             else if d2 >= 65 then d2 - 55
             else d2 - 48
  in
  Char.chr (val1 * 16 + val2)

(* To convert integer literals, allowing max_int + 1 (PR#4210) *)

let cvt_int_literal s =
  - int_of_string ("-" ^ s)
let cvt_int32_literal s =
  Int32.neg (Int32.of_string ("-" ^ String.sub s 0 (String.length s - 1)))
let cvt_int64_literal s =
  Int64.neg (Int64.of_string ("-" ^ String.sub s 0 (String.length s - 1)))
let cvt_nativeint_literal s =
  Nativeint.neg (Nativeint.of_string ("-" ^ String.sub s 0 (String.length s - 1)))

(* Remove underscores from float literals *)

let remove_underscores s =
  let l = String.length s in
  let rec remove src dst =
    if src >= l then
      if dst >= l then s else String.sub s 0 dst
    else
      match s.[src] with
        '_' -> remove (src + 1) dst
      |  c  -> s.[dst] <- c; remove (src + 1) (dst + 1)
  in
  remove 0 0

(* Update the current location with file name and line number. *)

let update_loc lexbuf file line absolute chars =
  let pos = lexbuf.lex_curr_p in
  let new_file = match file with
    | None -> pos.pos_fname
    | Some s -> s
  in
  lexbuf.lex_curr_p <- { pos with
                         pos_fname = new_file;
                         pos_lnum = if absolute then line else pos.pos_lnum + line;
                         pos_bol = pos.pos_cnum - chars;
                       }

(* Error report *)

open Format

let report_error ppf = function
  | Illegal_character c ->
    fprintf ppf "Illegal character (%s)" (Char.escaped c)
  | Illegal_escape s ->
    fprintf ppf "Illegal backslash escape in string or character (%s)" s
  | Unterminated_comment _ ->
    fprintf ppf "Comment not terminated"
  | Unterminated_string ->
    fprintf ppf "String literal not terminated"
  | Unterminated_string_in_comment _ ->
    fprintf ppf "This comment contains an unterminated string literal"
  | Keyword_as_label kwd ->
    fprintf ppf "`%s' is a keyword, it cannot be used as label name" kwd
  | Literal_overflow ty ->
    fprintf ppf "Integer literal exceeds the range of representable
                \ integers of type %s" ty
}

let newline = ('\010' | '\013' | "\013\010")
let blank = [' ' '\009' '\012']
let lowercase = ['a'-'z' '\223'-'\246' '\248'-'\255' '_']
let uppercase = ['A'-'Z' '\192'-'\214' '\216'-'\222']
let identchar =
  ['A'-'Z' 'a'-'z' '_' '\192'-'\214' '\216'-'\246' '\248'-'\255' '\'' '0'-'9']
let symbolchar =
  ['!' '$' '%' '&' '*' '+' '-' '.' '/' ':' '<' '=' '>' '?' '@' '^' '|' '~']
let decimal_literal =
  ['0'-'9'] ['0'-'9' '_']*
let hex_literal =
  '0' ['x' 'X'] ['0'-'9' 'A'-'F' 'a'-'f']['0'-'9' 'A'-'F' 'a'-'f' '_']*
let oct_literal =
  '0' ['o' 'O'] ['0'-'7'] ['0'-'7' '_']*
let bin_literal =
  '0' ['b' 'B'] ['0'-'1'] ['0'-'1' '_']*
let int_literal =
  decimal_literal | hex_literal | oct_literal | bin_literal
let float_literal =
  ['0'-'9'] ['0'-'9' '_']*
  ('.' ['0'-'9' '_']* )?
  (['e' 'E'] ['+' '-']? ['0'-'9'] ['0'-'9' '_']*)?

rule token state = refill {refill_handler} parse
| newline
  { update_loc lexbuf None 1 false 0;
    token state lexbuf
  }
| blank +
  { token state lexbuf }
| "_"
  { return UNDERSCORE }
| "~"
  { return TILDE }
| "~" lowercase identchar * ':'
  { let s = Lexing.lexeme lexbuf in
    let name = String.sub s 1 (String.length s - 2) in
    if Hashtbl.mem keyword_table name
    then error (Keyword_as_label name) (Location.curr lexbuf)
    else return (LABEL name)
  }
| "?"
  { return QUESTION }
| "?" lowercase identchar * ':'
  { let s = Lexing.lexeme lexbuf in
    let name = String.sub s 1 (String.length s - 2) in
    if Hashtbl.mem keyword_table name
    then error (Keyword_as_label name) (Location.curr lexbuf)
    else return (OPTLABEL name)
  }
| lowercase identchar *
  { let s = Lexing.lexeme lexbuf in
    return (try Hashtbl.find state.keywords s
            with Not_found ->
            try Hashtbl.find keyword_table s
            with Not_found ->
              LIDENT s)
  }
| uppercase identchar *
  { (* Capitalized keywords for OUnit *)
    let s = Lexing.lexeme lexbuf in
    return (try Hashtbl.find state.keywords s
            with Not_found ->
            try Hashtbl.find keyword_table s
            with Not_found ->
              UIDENT s)
  }
| int_literal
  { try
      return (INT (cvt_int_literal (Lexing.lexeme lexbuf)))
    with Failure _ ->
      error (Literal_overflow "int") (Location.curr lexbuf)
  }
| float_literal
  { return (FLOAT (remove_underscores (Lexing.lexeme lexbuf))) }
| int_literal "l"
  { try
      return (INT32 (cvt_int32_literal (Lexing.lexeme lexbuf)))
    with Failure _ ->
      error (Literal_overflow "int32") (Location.curr lexbuf)
  }
| int_literal "L"
  { try
      return (INT64 (cvt_int64_literal (Lexing.lexeme lexbuf)))
    with Failure _ ->
      error (Literal_overflow "int64") (Location.curr lexbuf)
  }
| int_literal "n"
  { try
      return (NATIVEINT (cvt_nativeint_literal (Lexing.lexeme lexbuf)))
    with Failure _ ->
      error (Literal_overflow "nativeint") (Location.curr lexbuf)
  }
| "\""
  { Buffer.reset state.buffer;
    state.string_start_loc <- Location.curr lexbuf;
    string state lexbuf >>= fun () ->
    lexbuf.lex_start_p <- state.string_start_loc.Location.loc_start;
    state.string_start_loc <- Location.none;
    return (STRING (Buffer.contents state.buffer))
  }
| "'" newline "'"
  { update_loc lexbuf None 1 false 1;
    return (CHAR (Lexing.lexeme_char lexbuf 1)) }
| "'" [^ '\\' '\'' '\010' '\013'] "'"
  { return (CHAR (Lexing.lexeme_char lexbuf 1)) }
| "'\\" ['\\' '\'' '"' 'n' 't' 'b' 'r' ' '] "'"
  { return (CHAR (char_for_backslash (Lexing.lexeme_char lexbuf 2))) }
| "'\\" ['0'-'9'] ['0'-'9'] ['0'-'9'] "'"
  { char_for_decimal_code state lexbuf 2 >>= fun c -> return (CHAR c) }
| "'\\" 'x' ['0'-'9' 'a'-'f' 'A'-'F'] ['0'-'9' 'a'-'f' 'A'-'F'] "'"
  { return (CHAR (char_for_hexadecimal_code lexbuf 3)) }
| "'\\" _
  { let l = Lexing.lexeme lexbuf in
    let esc = String.sub l 1 (String.length l - 1) in
    error (Illegal_escape esc) (Location.curr lexbuf)
  }
| "(*"
  { let start_loc = Location.curr lexbuf in
    state.comment_start_loc <- [start_loc];
    Buffer.reset state.buffer;
    comment state lexbuf >>= fun end_loc ->
    let s = Buffer.contents state.buffer in
    Buffer.reset state.buffer;
    return (COMMENT (s, { start_loc with Location.loc_end = end_loc.Location.loc_end }))
  }
| "(*)"
  { let loc = Location.curr lexbuf in
    Location.prerr_warning loc Warnings.Comment_start;
    state.comment_start_loc <- [loc];
    Buffer.reset state.buffer;
    comment state lexbuf >>= fun end_loc ->
    let s = Buffer.contents state.buffer in
    Buffer.reset state.buffer;
    return (COMMENT (s, { loc with Location.loc_end = end_loc.Location.loc_end }))
  }
| "*)"
  { let loc = Location.curr lexbuf in
    Location.prerr_warning loc Warnings.Comment_not_end;
    lexbuf.Lexing.lex_curr_pos <- lexbuf.Lexing.lex_curr_pos - 1;
    let curpos = lexbuf.lex_curr_p in
    lexbuf.lex_curr_p <- { curpos with pos_cnum = curpos.pos_cnum - 1 };
    return STAR
  }
| "#" [' ' '\t']* (['0'-'9']+ as num) [' ' '\t']*
      ("\"" ([^ '\010' '\013' '"' ] * as name) "\"")?
      [^ '\010' '\013'] * newline
  { update_loc lexbuf name (int_of_string num) true 0;
    token state lexbuf
  }

| "<:" identchar* ("@" identchar*)? "<"
| "<@" identchar* "<"
| "<<" identchar
  { let start = lexbuf.lex_start_p in
    p4_quotation lexbuf >>= fun () ->
    lexbuf.lex_start_p <- start;
    return P4_QUOTATION
  }

| "#"  { return SHARP }
| "&"  { return AMPERSAND }
| "&&" { return AMPERAMPER }
| "`"  { return BACKQUOTE }
| "'"  { return QUOTE }
| "("  { return LPAREN }
| ")"  { return RPAREN }
| "*"  { return STAR }
| ","  { return COMMA }
| "->" { return MINUSGREATER }
| "."  { return DOT }
| ".." { return DOTDOT }
| ":"  { return COLON }
| "::" { return COLONCOLON }
| ":=" { return COLONEQUAL }
| ":>" { return COLONGREATER }
| ";"  { return SEMI }
| ";;" { return SEMISEMI }
| "<"  { return LESS }
| "<-" { return LESSMINUS }
| "="  { return EQUAL }
| "["  { return LBRACKET }
| "[|" { return LBRACKETBAR }
| "[<" { return LBRACKETLESS }
| "[>" { return LBRACKETGREATER }
| "]"  { return RBRACKET }
| "{"  { return LBRACE }
| "{<" { return LBRACELESS }
| "|"  { return BAR }
| "||" { return BARBAR }
| "|]" { return BARRBRACKET }
| ">"  { return GREATER }
| ">]" { return GREATERRBRACKET }
| "}"  { return RBRACE }
| ">}" { return GREATERRBRACE }
| "!"  { return BANG }

| "!=" { return (INFIXOP0 "!=") }
| "+"  { return PLUS }
| "+." { return PLUSDOT }
| "-"  { return MINUS }
| "-." { return MINUSDOT }

| "!" symbolchar +
  { return (PREFIXOP(Lexing.lexeme lexbuf)) }
| ['~' '?'] symbolchar +
  { return (PREFIXOP(Lexing.lexeme lexbuf)) }
| ['=' '<' '>' '|' '&' '$'] symbolchar *
  { return (INFIXOP0(Lexing.lexeme lexbuf)) }
| ['@' '^'] symbolchar *
  { return (INFIXOP1(Lexing.lexeme lexbuf)) }
| ['+' '-'] symbolchar *
  { return (INFIXOP2(Lexing.lexeme lexbuf)) }
| "**" symbolchar *
  { return (INFIXOP4(Lexing.lexeme lexbuf)) }
| ['*' '/' '%'] symbolchar *
  { return (INFIXOP3(Lexing.lexeme lexbuf)) }
| eof
  { return EOF }
| _
  { error (Illegal_character (Lexing.lexeme_char lexbuf 0))
          (Location.curr lexbuf) }

and comment state = refill {refill_handler} parse
  "(*"
  { state.comment_start_loc <-
            (Location.curr lexbuf) :: state.comment_start_loc;
    Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
    comment state lexbuf
  }
| "*)"
  { match state.comment_start_loc with
    | [] -> assert false
    | [_] ->
      state.comment_start_loc <- [];
      return (Location.curr lexbuf)
    | _ :: l ->
      state.comment_start_loc <- l;
      Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
      comment state lexbuf
  }
| "\""
  {
    state.string_start_loc <- Location.curr lexbuf;
    Buffer.add_char state.buffer '"';
    (catch (string state lexbuf) (fun e l ->
      match e with
      | Unterminated_string ->
        begin match state.comment_start_loc with
        | [] -> assert false
        | loc :: _ ->
          let start = List.hd (List.rev state.comment_start_loc) in
          state.comment_start_loc <- [];
          error (Unterminated_string_in_comment start) loc
        end
      | e -> error e l
    )) >>= fun () ->
    state.string_start_loc <- Location.none;
    Buffer.add_char state.buffer '"';
    comment state lexbuf
  }
| "''"
  { Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
    comment state lexbuf
  }
| "'" newline "'"
  { update_loc lexbuf None 1 false 1;
    Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
    comment state lexbuf
  }
| "'" [^ '\\' '\'' '\010' '\013' ] "'"
  { Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
    comment state lexbuf
  }
| "'\\" ['\\' '"' '\'' 'n' 't' 'b' 'r' ' '] "'"
  { Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
    comment state lexbuf
  }
| "'\\" ['0'-'9'] ['0'-'9'] ['0'-'9'] "'"
  { Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
    comment state lexbuf
  }
| "'\\" 'x' ['0'-'9' 'a'-'f' 'A'-'F'] ['0'-'9' 'a'-'f' 'A'-'F'] "'"
  { Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
    comment state lexbuf
  }
| eof
  { match state.comment_start_loc with
    | [] -> assert false
    | loc :: _ ->
      let start = List.hd (List.rev state.comment_start_loc) in
      state.comment_start_loc <- [];
      error (Unterminated_comment start) loc
  }
| newline
  { update_loc lexbuf None 1 false 0;
    Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
    comment state lexbuf
  }
| _
  { Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
    comment state lexbuf
  }

and string state = refill {refill_handler} parse
  '"'
  { return () }
| '\\' newline ([' ' '\t'] * as space)
  { update_loc lexbuf None 1 false (String.length space);
    string state lexbuf
  }
| '\\' ['\\' '\'' '"' 'n' 't' 'b' 'r' ' ']
  { Buffer.add_char state.buffer
      (char_for_backslash (Lexing.lexeme_char lexbuf 1));
    string state lexbuf
  }
| '\\' ['0'-'9'] ['0'-'9'] ['0'-'9']
  { char_for_decimal_code state lexbuf 1 >>= fun c ->
    Buffer.add_char state.buffer c;
    string state lexbuf
  }
| '\\' 'x' ['0'-'9' 'a'-'f' 'A'-'F'] ['0'-'9' 'a'-'f' 'A'-'F']
  { Buffer.add_char state.buffer (char_for_hexadecimal_code lexbuf 2);
    string state lexbuf
  }
| '\\' _
  { if in_comment state
    then string state lexbuf
    else begin
      (*  Should be an error, but we are very lax.
          error (Illegal_escape (Lexing.lexeme lexbuf),
                        Location.curr lexbuf))
      *)
      let loc = Location.curr lexbuf in
      Location.prerr_warning loc Warnings.Illegal_backslash;
      Buffer.add_char state.buffer (Lexing.lexeme_char lexbuf 0);
      Buffer.add_char state.buffer (Lexing.lexeme_char lexbuf 1);
      string state lexbuf
    end
  }
| newline
  { if not (in_comment state) then
      Location.prerr_warning (Location.curr lexbuf) Warnings.Eol_in_string;
    update_loc lexbuf None 1 false 0;
    Buffer.add_string state.buffer (Lexing.lexeme lexbuf);
    string state lexbuf
  }
| eof
  { error Unterminated_string state.string_start_loc }
| _
  { Buffer.add_char state.buffer (Lexing.lexeme_char lexbuf 0);
    string state lexbuf
  }

and skip_sharp_bang = refill {refill_handler'} parse
| "#!" [^ '\n']* '\n' [^ '\n']* "\n!#\n"
  { update_loc lexbuf None 3 false 0;
    return ()
  }
| "#!" [^ '\n']* '\n'
  { update_loc lexbuf None 1 false 0;
    return ()
  }
| "" { return () }

and p4_quotation = refill {refill_handler'} parse
| "<" (":" identchar*)? ("@" identchar*)? "<"
  { p4_quotation lexbuf }
  (* FIXME: This is fake *)
| ">>"
  { return () }
| eof
  { error Unterminated_string Location.none }
| _
  { p4_quotation lexbuf }

{
type comment = string * Location.t

let rec token_without_comments state lexbuf =
  token state lexbuf >>= function
  | COMMENT (s, comment_loc) ->
      token_without_comments state lexbuf
  | tok -> return tok
}
