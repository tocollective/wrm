# 9. Грамматика

[← Диагностика](08-diagnostics.md) · [Оглавление](README.md)

Сводка синтаксиса в EBNF. `{ x }` — ноль или больше раз, `[ x ]` —
необязательно, `|` — выбор, `"..."` — токен. Лексика —
[раздел 1](01-lexical.md), приоритеты — [4.1](04-expressions.md#41-приоритеты).
Там, где грамматика неоднозначна, действуют правила из текста; они
отмечены `(* ... *)`.

## Файл

```ebnf
file        = { top_decl } ;

top_decl    = import_decl
            | export_decl
            | struct_decl
            | alias_decl
            | enum_decl
            | [ "align" "(" const_expr ")" ] var_decl
            | func_decl
            | extern_decl ;

import_decl = "import" "{" name_as { "," name_as } [ "," ] "}"
              "from" string_literal ;
export_decl = "export" "{" name_as { "," name_as } [ "," ] "}" ;
name_as     = identifier [ "as" identifier ] ;
```

## Типы

```ebnf
struct_decl = [ "packed" ] "type" identifier
              "{" field { "," field } [ "," ] "}" ;
field       = identifier ":" type ;

alias_decl  = "type" identifier "=" type ;
              (* после 'type identifier': '{' — структура, '=' — псевдоним *)

enum_decl   = "enum" identifier ":" type
              "{" enum_item { "," enum_item } [ "," ] "}" ;
enum_item   = identifier [ "=" const_expr ] ;

type        = prefix_type { "[" const_expr "]" } ;
              (* '[N]' относится ко всему типу слева *)
prefix_type = "*" [ "volatile" ] [ "mut" ] prefix_type
            | func_type
            | "(" type ")"
            | type_name ;
func_type   = "(" [ param { "," param } [ "," ] ] ")" ":" type ;
              (* '(' и затем ')' или 'identifier :' — тип функции,
                 иначе — скобки вокруг типа *)
type_name   = "Byte" | "UByte" | "Half" | "UHalf" | "Word" | "UWord"
            | "Bool" | "Float" | "Void" | identifier ;

param_type  = [ "mut" ] type "[" "]"      (* только в параметре *)
            | type
            | "..." ;                    (* только последний параметр *)
```

## Объявления

```ebnf
var_decl    = "let" [ "mut" ] identifier ":" ( type | type "[" "]" ) [ "=" expr ] ;
              (* T[] — длина из литерала массива в "=" (3.2) *)
func_decl   = "let" [ "mut" ] identifier "(" [ param { "," param } [ "," ] ] ")"
              ":" type block ;
              (* после 'let [mut] identifier': ':' — переменная,
                 '(' — функция *)
param       = identifier ":" param_type ;
extern_decl = "extern" "let" identifier
              "(" [ param { "," param } [ "," ] ] ")" ":" type
            | "extern" "let" [ "mut" ] identifier ":" type ;
```

## Операторы

```ebnf
block       = "{" { statement } "}" ;

statement   = var_decl
            | func_decl
            | block
            | if_stmt
            | while_stmt
            | for_stmt
            | switch_stmt
            | "break"
            | "continue"
            | "return" [ expr ]
            | asm_stmt
            | simple_stmt ;

simple_stmt = place assign_op expr
            | place ( "++" | "--" )
            | call ;
assign_op   = "=" | "+=" | "-=" | "*=" | "/=" | "%="
            | "&=" | "|=" | "^=" | "<<=" | ">>=" ;
place       = postfix_expr | "*" unary_expr ;

body        = block | statement ;
              (* не var_decl и не func_decl *)
condition   = "(" expr ")"
            | expr ;
              (* если первый токен '(' — условие ровно в этих скобках;
                 иначе — самое длинное выражение *)

if_stmt     = "if" condition body [ "else" body ] ;
              (* else — к ближайшему if без else *)
while_stmt  = "while" condition body ;
for_stmt    = "for" [ "mut" ] identifier ":" type "in"
              expr ( ".." | "..." ) condition_end
              [ "by" const_expr ] body ;
condition_end = expr ;
              (* по тем же правилам границы, что и condition *)

switch_stmt = "switch" expr "{" { switch_case } "}" ;
switch_case = ( "case" const_expr | "default" ) ":" { case_stmt } ;
case_stmt   = statement ;
              (* кроме var_decl и func_decl: объявления — в блоке *)

asm_stmt    = "asm" "{" string_literal { string_literal } "}" ;
```

Граница `return`: тип результата функции известен до её тела, поэтому
в `Void`-функции `return` **никогда** не берёт выражение, а в функции с
результатом — **всегда** берёт. Так `if done return` и следующая строка
`x = 1` — это два оператора, а не `return x`.

В условии `if`, `while`, `for` и в выражении `switch` литерал структуры
`{ ... }` и литерал функции на верхнем уровне не допускаются: `{` там
начинает тело. Внутри скобок — можно.

## Выражения

```ebnf
expr        = or_expr ;
or_expr     = and_expr { "||" and_expr } ;
and_expr    = cmp_expr { "&&" cmp_expr } ;
cmp_expr    = bor_expr [ cmp_op bor_expr ] ;          (* без цепочек *)
cmp_op      = "==" | "!=" | "<" | "<=" | ">" | ">=" ;
bor_expr    = bxor_expr { "|" bxor_expr } ;
bxor_expr   = band_expr { "^" band_expr } ;
band_expr   = shift_expr { "&" shift_expr } ;
shift_expr  = add_expr { ( "<<" | ">>" ) add_expr } ;
add_expr    = mul_expr { ( "+" | "-" | "+|" | "-|" ) mul_expr } ;
mul_expr    = cast_expr { ( "*" | "/" | "%" | "*|" ) cast_expr } ;
cast_expr   = unary_expr { "as" type } ;
unary_expr  = ( "-" | "!" | "~" | "*" | "&" [ "mut" ] ) unary_expr
            | postfix_expr ;
postfix_expr = primary { call_suffix | "[" expr "]" | "." identifier } ;
call_suffix = "(" [ expr { "," expr } [ "," ] ] ")" ;
call        = postfix_expr call_suffix ;

primary     = int_literal | float_literal | char_literal | string_literal
            | "true" | "false" | "null"
            | identifier
            | identifier "." identifier          (* элемент enum *)
            | "(" expr ")"
            | struct_lit
            | func_lit
            | array_lit
            | builtin_call ;

func_lit    = "(" [ param { "," param } [ "," ] ] ")" ":" type block ;
              (* '(' и затем ')' или 'identifier :' — литерал функции,
                 иначе — выражение в скобках *)
struct_lit  = "{" [ field_init { "," field_init } [ "," ] ] "}" ;
field_init  = "." identifier "=" expr ;
array_lit   = "[" [ expr { "," expr } [ "," ] ] "]" ;

builtin_call = ( "sizeof" | "alignof" ) "(" ( type | expr ) ")"
              (* имя переменной — значение, имя типа — тип (7.2) *)
             | "offsetof" "(" type "," identifier ")"
             | "vaArg" "(" expr "," expr "," type ")"
             | builtin_name call_suffix ;
builtin_name = "mfcr" | "mtcr" | "syscall" | "wfi" | "hlt" | "tlbi"
             | "fence" | "breakpoint" | "clz" | "ctz" | "popcount"
             | "bswap" | "rotl" | "rotr" | "atomicLoad" | "atomicStore"
             | "atomicSwap" | "atomicAdd" | "atomicCompareSwap" | "vaCount" ;

const_expr  = expr ;                        (* значение известно при компиляции *)
```

- `{` в начале выражения — всегда литерал структуры: блок не бывает
  выражением.
- `[` в начале выражения — литерал массива, после выражения — индекс.
- `(` в начале выражения, за которой идёт `)` или `identifier ":"`, —
  литерал функции, иначе — выражение в скобках.
- `identifier "." identifier` — элемент `enum`, если слева имя `enum`,
  иначе — поле.
