(* minijx: Jinja expression -> Python expression.

  Syntax-directed translation with Jinja's precedence (lowest first):
    a if b else c, or, and, not, comparisons, + -, ~, * / // %, **, unary,
    primary . [] (), | filter, is test.

  Name resolution: names bound in the template (arguments, set, for targets,
  content, attrs) are emitted as-is; `loop` maps to the scope's loop variable;
  a short list of Python builtins passes through; every other name becomes
  `_globals["name"]`. *)
unit mjexpr;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, mjerrors, mjutil;

type
  TScope = class
  private
    FNames: TStringList;
  public
    Parent: TScope;
    LoopVar: string; (* Python name the template's `loop` refers to, '' if none *)
    constructor Create(AParent: TScope);
    destructor Destroy; override;
    procedure Add(const Name: string);
    function IsLocal(const Name: string): Boolean;
    function FindLoopVar: string;
  end;

  TXTokKind = (xkName, xkInt, xkFloat, xkStr, xkOp, xkEOF);

  (* What the expression parsed so far looks like; used to compile
    `x is defined` and `x|default(...)` without raising on missing names. *)
  TShape = (shOther, shLocal, shGlobal, shAttr, shItem);

  TExprTranslator = class
  private
    FFile: string;
    FFileSrc: string;
    FSrc: string;
    FBase: Integer; (* 1-based offset of FSrc[1] in FFileSrc *)
    FScope: TScope;
    (* tokens *)
    FPos: Integer;
    FTokKind: TXTokKind;
    FTokVal: string;
    FTokPos: Integer;
    (* shape of the last primary+postfix *)
    FShape: TShape;
    FShapeObj: string;
    FShapeKey: string;
    (* the callee and arguments of the call ParsePostfix parsed last *)
    FLastCallee: string;
    FLastArgs: string;
    procedure Fail(TokPos: Integer; const Msg: string);
    procedure Next;
    function IsName(const V: string): Boolean;
    function IsOp(const V: string): Boolean;
    procedure Expect(const V: string);
    function ParseExpression: string;
    function ParseCondExpr: string;
    function ParseOr: string;
    function ParseAnd: string;
    function ParseNot: string;
    function ParseCompare: string;
    function ParseMath1: string;
    function ParseConcat: string;
    function ParseMath2: string;
    function ParsePow: string;
    function ParseUnary(WithFilter: Boolean = True): string;
    function ParsePrimary: string;
    function ParsePostfix(const E: string): string;
    function ParseFilterExpr(const E: string): string;
    function ParseCallArgs(out Args: string): Boolean;
    function ParseList: string;
    function ParseDict: string;
    function ParseTupleOrParen: string;
    function ResolveName(const Name: string; TokPos: Integer): string;
    function SafeSubject(const E: string): string;
    function FilterCall(const Name, Subject, Args: string): string;
    function TestCall(const Name, Subject, Args: string): string;
  public
    UsesLoop: Boolean;
    (* the expression calls a filter / a test looked up by name *)
    UsesFilters: Boolean;
    UsesTests: Boolean;
    constructor Create(const AFile, AFileSrc, ASrc: string; ABase: Integer;
      AScope: TScope);
    (* Translate the whole source as one expression. *)
    function Translate: string;
    (* `a, b` or `(a, b)` or `a`: Python target plus the names it binds. *)
    function TranslateTarget(out Names: TStringArray): string;
    (* For `{% for target in iter [if cond] [recursive] %}`. *)
    procedure TranslateFor(out Target: string; out Names: TStringArray;
      out Iter: string; out Cond: string; out Recursive: Boolean; IterScope: TScope);
    (* For `{% set name = expr %}`. *)
    procedure TranslateSet(out Name: string; out Value: string);
    (* `{% filter upper|replace("a", "b") %}` applied to Subject. *)
    function TranslateFilterChain(const Subject: string): string;
    (* `{% call fn(args) %}`: the Python call with Body as first argument. *)
    function TranslateCallBlock(const Body: string): string;
  end;

const
  PyBuiltins: array[0..22] of string = ('range', 'dict', 'list', 'tuple', 'set',
    'len', 'min', 'max', 'sum', 'abs', 'round', 'str', 'int', 'float', 'bool',
    'zip', 'enumerate', 'sorted', 'reversed', 'isinstance', 'getattr', 'hasattr',
    'print');

implementation

(* TScope *)

constructor TScope.Create(AParent: TScope);
begin
  Parent := AParent;
  FNames := TStringList.Create;
  FNames.Sorted := True;
  FNames.Duplicates := dupIgnore;
  FNames.CaseSensitive := True;
end;

destructor TScope.Destroy;
begin
  FNames.Free;
  inherited;
end;

procedure TScope.Add(const Name: string);
begin
  FNames.Add(Name);
end;

function TScope.IsLocal(const Name: string): Boolean;
var
  S: TScope;
begin
  S := Self;
  while S <> nil do
  begin
    if S.FNames.IndexOf(Name) >= 0 then
      Exit(True);
    S := S.Parent;
  end;
  Result := False;
end;

function TScope.FindLoopVar: string;
var
  S: TScope;
begin
  S := Self;
  while S <> nil do
  begin
    if S.LoopVar <> '' then
      Exit(S.LoopVar);
    S := S.Parent;
  end;
  Result := '';
end;

(* TExprTranslator *)

constructor TExprTranslator.Create(const AFile, AFileSrc, ASrc: string; ABase: Integer;
  AScope: TScope);
begin
  FFile := AFile;
  FFileSrc := AFileSrc;
  FSrc := ASrc;
  FBase := ABase;
  FScope := AScope;
  FPos := 1;
  UsesLoop := False;
  Next;
end;

procedure TExprTranslator.Fail(TokPos: Integer; const Msg: string);
begin
  CompileError(FFile, FFileSrc, FBase + TokPos - 1, Msg);
end;

procedure TExprTranslator.Next;
var
  L, Start: Integer;
  C, Quote: Char;
  Two: string;
begin
  L := Length(FSrc);
  while (FPos <= L) and (FSrc[FPos] in WhitespaceChars) do
    Inc(FPos);
  FTokPos := FPos;
  if FPos > L then
  begin
    FTokKind := xkEOF;
    FTokVal := '';
    Exit;
  end;
  C := FSrc[FPos];
  if C in NameStartChars then
  begin
    Start := FPos;
    while (FPos <= L) and (FSrc[FPos] in NameChars) do
      Inc(FPos);
    FTokKind := xkName;
    FTokVal := Copy(FSrc, Start, FPos - Start);
    Exit;
  end;
  if C in DigitChars then
  begin
    Start := FPos;
    FTokKind := xkInt;
    if (C = '0') and (FPos < L) and (FSrc[FPos + 1] in ['x', 'X', 'b', 'B', 'o', 'O']) then
    begin
      Inc(FPos, 2);
      while (FPos <= L) and (FSrc[FPos] in ['0'..'9', 'a'..'f', 'A'..'F', '_']) do
        Inc(FPos);
    end
    else
    begin
      while (FPos <= L) and (FSrc[FPos] in ['0'..'9', '_']) do
        Inc(FPos);
      if (FPos < L) and (FSrc[FPos] = '.') and (FSrc[FPos + 1] in DigitChars) then
      begin
        FTokKind := xkFloat;
        Inc(FPos);
        while (FPos <= L) and (FSrc[FPos] in ['0'..'9', '_']) do
          Inc(FPos);
      end;
      if (FPos <= L) and (FSrc[FPos] in ['e', 'E']) then
      begin
        FTokKind := xkFloat;
        Inc(FPos);
        if (FPos <= L) and (FSrc[FPos] in ['+', '-']) then
          Inc(FPos);
        while (FPos <= L) and (FSrc[FPos] in DigitChars) do
          Inc(FPos);
      end;
    end;
    FTokVal := Copy(FSrc, Start, FPos - Start);
    Exit;
  end;
  if C in ['"', ''''] then
  begin
    Quote := C;
    Start := FPos;
    Inc(FPos);
    while (FPos <= L) and (FSrc[FPos] <> Quote) do
    begin
      if FSrc[FPos] = '\' then
        Inc(FPos);
      Inc(FPos);
    end;
    if FPos > L then
      Fail(Start, 'Unclosed string');
    Inc(FPos);
    FTokKind := xkStr;
    FTokVal := Copy(FSrc, Start, FPos - Start);
    Exit;
  end;
  FTokKind := xkOp;
  Two := Copy(FSrc, FPos, 2);
  if InList(Two, ['**', '//', '==', '!=', '<=', '>=']) then
  begin
    FTokVal := Two;
    Inc(FPos, 2);
    Exit;
  end;
  if C in ['+', '-', '*', '/', '%', '~', '<', '>', '(', ')', '[', ']', '{', '}',
    ',', ':', '|', '.', '=', ';'] then
  begin
    FTokVal := C;
    Inc(FPos);
    Exit;
  end;
  Fail(FPos, 'Unexpected character `' + C + '`');
end;

function TExprTranslator.IsName(const V: string): Boolean;
begin
  Result := (FTokKind = xkName) and (FTokVal = V);
end;

function TExprTranslator.IsOp(const V: string): Boolean;
begin
  Result := (FTokKind = xkOp) and (FTokVal = V);
end;

procedure TExprTranslator.Expect(const V: string);
begin
  if not (IsOp(V) or IsName(V)) then
  begin
    if FTokKind = xkEOF then
      Fail(FTokPos, 'Expected `' + V + '` but the expression ended')
    else
      Fail(FTokPos, 'Expected `' + V + '` but found `' + FTokVal + '`');
  end;
  Next;
end;

function TExprTranslator.Translate: string;
begin
  Result := ParseExpression;
  if FTokKind <> xkEOF then
    Fail(FTokPos, 'Unexpected `' + FTokVal + '`');
end;

function TExprTranslator.ParseExpression: string;
begin
  Result := ParseCondExpr;
end;

function TExprTranslator.ParseCondExpr: string;
var
  Cond, Alt: string;
begin
  Result := ParseOr;
  while IsName('if') do
  begin
    Next;
    Cond := ParseOr;
    if IsName('else') then
    begin
      Next;
      Alt := ParseCondExpr();
    end
    else
      Alt := '""'; (* Jinja renders a missing else as an empty string *)
    Result := '(' + Result + ' if ' + Cond + ' else ' + Alt + ')';
    FShape := shOther;
  end;
end;

function TExprTranslator.ParseOr: string;
begin
  Result := ParseAnd;
  while IsName('or') do
  begin
    Next;
    Result := '(' + Result + ' or ' + ParseAnd + ')';
    FShape := shOther;
  end;
end;

function TExprTranslator.ParseAnd: string;
begin
  Result := ParseNot;
  while IsName('and') do
  begin
    Next;
    Result := '(' + Result + ' and ' + ParseNot + ')';
    FShape := shOther;
  end;
end;

function TExprTranslator.ParseNot: string;
begin
  if IsName('not') then
  begin
    Next;
    Result := '(not ' + ParseNot() + ')';
    FShape := shOther;
  end
  else
    Result := ParseCompare;
end;

function TExprTranslator.ParseCompare: string;
var
  Op: string;
  Chained: Boolean;
begin
  Result := ParseMath1;
  Chained := False;
  while True do
  begin
    if (FTokKind = xkOp) and InList(FTokVal, ['==', '!=', '<', '>', '<=', '>=']) then
    begin
      Op := FTokVal;
      Next;
    end
    else if IsName('in') then
    begin
      Op := 'in';
      Next;
    end
    else if IsName('not') then
    begin
      Next;
      if not IsName('in') then
        Fail(FTokPos, 'Expected `in` after `not`');
      Next;
      Op := 'not in';
    end
    else
      Break;
    Result := Result + ' ' + Op + ' ' + ParseMath1;
    Chained := True;
  end;
  if Chained then
  begin
    Result := '(' + Result + ')';
    FShape := shOther;
  end;
end;

function TExprTranslator.ParseMath1: string;
var
  Op: string;
begin
  Result := ParseConcat;
  while (FTokKind = xkOp) and ((FTokVal = '+') or (FTokVal = '-')) do
  begin
    Op := FTokVal;
    Next;
    Result := '(' + Result + ' ' + Op + ' ' + ParseConcat + ')';
    FShape := shOther;
  end;
end;

function TExprTranslator.ParseConcat: string;
var
  Parts: string;
begin
  Result := ParseMath2;
  if IsOp('~') then
  begin
    Parts := Result;
    while IsOp('~') do
    begin
      Next;
      Parts := Parts + ', ' + ParseMath2;
    end;
    Result := 'concat(' + Parts + ')';
    FShape := shOther;
  end;
end;

function TExprTranslator.ParseMath2: string;
var
  Op: string;
begin
  Result := ParsePow;
  while (FTokKind = xkOp) and InList(FTokVal, ['*', '/', '//', '%']) do
  begin
    Op := FTokVal;
    Next;
    Result := '(' + Result + ' ' + Op + ' ' + ParsePow + ')';
    FShape := shOther;
  end;
end;

function TExprTranslator.ParsePow: string;
begin
  Result := ParseUnary;
  (* Jinja's ** is left associative, Python's is right; keep Jinja's *)
  while IsOp('**') do
  begin
    Next;
    Result := '(' + Result + ' ** ' + ParseUnary + ')';
    FShape := shOther;
  end;
end;

function TExprTranslator.ParseUnary(WithFilter: Boolean): string;
begin
  if IsOp('-') then
  begin
    Next;
    Result := '(-' + ParseUnary(False) + ')';
    FShape := shOther;
  end
  else if IsOp('+') then
  begin
    Next;
    Result := '(+' + ParseUnary(False) + ')';
    FShape := shOther;
  end
  else
  begin
    Result := ParsePrimary;
    Result := ParsePostfix(Result);
  end;
  if WithFilter then
    Result := ParseFilterExpr(Result);
end;

function TExprTranslator.ResolveName(const Name: string; TokPos: Integer): string;
var
  LV: string;
begin
  FShape := shOther;
  if (Name = 'true') or (Name = 'True') then
    Exit('True');
  if (Name = 'false') or (Name = 'False') then
    Exit('False');
  if (Name = 'none') or (Name = 'None') then
    Exit('None');
  if Name = 'loop' then
  begin
    LV := FScope.FindLoopVar;
    if LV = '' then
      Fail(TokPos, '`loop` used outside of a for loop');
    UsesLoop := True;
    FShape := shLocal;
    Exit(LV);
  end;
  if FScope.IsLocal(Name) then
  begin
    FShape := shLocal;
    Exit(Name);
  end;
  if InList(Name, PyBuiltins) then
  begin
    FShape := shLocal;
    Exit(Name);
  end;
  FShape := shGlobal;
  FShapeKey := Name;
  Result := '_globals[' + PyStr(Name) + ']';
end;

function TExprTranslator.ParsePrimary: string;
var
  P: Integer;
begin
  P := FTokPos;
  case FTokKind of
    xkName:
      begin
        Result := ResolveName(FTokVal, P);
        Next;
      end;
    xkStr:
      begin
        Result := FTokVal;
        Next;
        (* adjacent literals concatenate, in Jinja and in Python *)
        while FTokKind = xkStr do
        begin
          Result := Result + ' ' + FTokVal;
          Next;
        end;
        FShape := shOther;
      end;
    xkInt, xkFloat:
      begin
        Result := FTokVal;
        Next;
        FShape := shOther;
      end;
    xkOp:
      begin
        if FTokVal = '(' then
          Result := ParseTupleOrParen
        else if FTokVal = '[' then
          Result := ParseList
        else if FTokVal = '{' then
          Result := ParseDict
        else
          Fail(P, 'Unexpected `' + FTokVal + '`');
        FShape := shOther;
      end;
  else
    Fail(P, 'Unexpected end of expression');
  end;
end;

function TExprTranslator.ParseTupleOrParen: string;
var
  Items: string;
  N: Integer;
  Trailing: Boolean;
begin
  Expect('(');
  Items := '';
  N := 0;
  Trailing := False;
  while not IsOp(')') do
  begin
    if N > 0 then
      Items := Items + ', ';
    Items := Items + ParseExpression;
    Inc(N);
    Trailing := False;
    if IsOp(',') then
    begin
      Next;
      Trailing := True;
    end
    else
      Break;
  end;
  Expect(')');
  if (N = 1) and not Trailing then
    Result := '(' + Items + ')'
  else if N = 1 then
    Result := '(' + Items + ',)'
  else
    Result := '(' + Items + ')';
end;

function TExprTranslator.ParseList: string;
var
  Items: string;
  N: Integer;
begin
  Expect('[');
  Items := '';
  N := 0;
  while not IsOp(']') do
  begin
    if N > 0 then
      Items := Items + ', ';
    Items := Items + ParseExpression;
    Inc(N);
    if IsOp(',') then
      Next
    else
      Break;
  end;
  Expect(']');
  Result := '[' + Items + ']';
end;

function TExprTranslator.ParseDict: string;
var
  Items, K: string;
  N: Integer;
begin
  Expect('{');
  Items := '';
  N := 0;
  while not IsOp('}') do
  begin
    if N > 0 then
      Items := Items + ', ';
    K := ParseExpression;
    Expect(':');
    Items := Items + K + ': ' + ParseExpression;
    Inc(N);
    if IsOp(',') then
      Next
    else
      Break;
  end;
  Expect('}');
  Result := '{' + Items + '}';
end;

(* Parses `(args)` at the current position. Returns False if there is no `(`.
  Keyword arguments whose name is a Python keyword go through `**{...}`. *)
function TExprTranslator.ParseCallArgs(out Args: string): Boolean;
var
  Pos, KW: string;
  Name: string;
  NamePos: Integer;
  SavePos: Integer;
  SaveKind: TXTokKind;
  SaveVal: string;
  SaveTokPos: Integer;
  IsKw: Boolean;
begin
  if not IsOp('(') then
    Exit(False);
  Next;
  Pos := '';
  KW := '';
  while not IsOp(')') do
  begin
    IsKw := False;
    if FTokKind = xkName then
    begin
      (* look ahead for `name=` (but not `name==`) *)
      SavePos := FPos;
      SaveKind := FTokKind;
      SaveVal := FTokVal;
      SaveTokPos := FTokPos;
      Name := FTokVal;
      NamePos := FTokPos;
      Next;
      if IsOp('=') then
      begin
        Next;
        IsKw := True;
      end
      else
      begin
        FPos := SavePos;
        FTokKind := SaveKind;
        FTokVal := SaveVal;
        FTokPos := SaveTokPos;
      end;
    end;
    if IsKw then
    begin
      if IsPyKeyword(Name) then
        KW := KW + PyStr(Name) + ': ' + ParseExpression + ', '
      else
        Pos := Pos + Name + '=' + ParseExpression + ', ';
    end
    else if IsOp('**') then
    begin
      Next;
      Pos := Pos + '**' + ParseExpression + ', ';
    end
    else if IsOp('*') then
    begin
      Next;
      Pos := Pos + '*' + ParseExpression + ', ';
    end
    else
      Pos := Pos + ParseExpression + ', ';
    if IsOp(',') then
      Next
    else
      Break;
  end;
  Expect(')');
  if KW <> '' then
    Pos := Pos + '**{' + Copy(KW, 1, Length(KW) - 2) + '}, ';
  if Pos <> '' then
    Pos := Copy(Pos, 1, Length(Pos) - 2);
  Args := Pos;
  Result := True;
end;

function TExprTranslator.ParsePostfix(const E: string): string;
var
  Args, A, B, C: string;
  Name: string;
  P: Integer;
  HasB, HasC: Boolean;
begin
  Result := E;
  while True do
  begin
    if IsOp('.') then
    begin
      Next;
      P := FTokPos;
      if FTokKind = xkName then
        Name := PyStr(FTokVal)
      else if FTokKind = xkInt then
        Name := FTokVal
      else
        Fail(P, 'Expected an attribute name after `.`');
      Next;
      FShapeObj := Result;
      FShapeKey := Name;
      FShape := shAttr;
      (* `attrs` and `loop` are runtime objects: plain attribute access *)
      if (FTokKind <> xkInt) and
        ((Result = 'attrs') or ((FScope <> nil) and (Result = FScope.FindLoopVar))) and
        (Copy(Name, 1, 1) = '''') then
        Result := Result + '.' + Copy(Name, 2, Length(Name) - 2)
      else
        Result := 'getattr_(' + Result + ', ' + Name + ')';
    end
    else if IsOp('[') then
    begin
      Next;
      (* slice or index *)
      A := '';
      B := '';
      C := '';
      HasB := False;
      HasC := False;
      if not IsOp(':') then
        A := ParseExpression;
      if IsOp(':') then
      begin
        HasB := True;
        Next;
        if not (IsOp(':') or IsOp(']')) then
          B := ParseExpression;
        if IsOp(':') then
        begin
          HasC := True;
          Next;
          if not IsOp(']') then
            C := ParseExpression;
        end;
      end;
      Expect(']');
      if HasB then
      begin
        Result := Result + '[' + A + ':' + B;
        if HasC then
          Result := Result + ':' + C;
        Result := Result + ']';
        FShape := shOther;
      end
      else
      begin
        FShapeObj := Result;
        FShapeKey := A;
        FShape := shItem;
        Result := 'getitem(' + Result + ', ' + A + ')';
      end;
    end
    else if IsOp('(') then
    begin
      ParseCallArgs(Args);
      FLastCallee := Result;
      FLastArgs := Args;
      Result := Result + '(' + Args + ')';
      FShape := shOther;
    end
    else
      Break;
  end;
end;

(* The subject expression rewritten so a missing name/attr/item yields None
  instead of raising; used by `|default` and `is defined`. *)
(* Filters and tests are looked up by name, in the dict the catalog passes in
   `_globals` (bound to `_f` / `_t` at the top of the component), so custom
   ones work and can replace builtin filters. *)
function TExprTranslator.FilterCall(const Name, Subject, Args: string): string;
begin
  UsesFilters := True;
  Result := '_f[' + PyStr(Name) + '](' + Subject;
  if Args <> '' then
    Result := Result + ', ' + Args;
  Result := Result + ')';
end;

function TExprTranslator.TestCall(const Name, Subject, Args: string): string;
begin
  UsesTests := True;
  Result := '_t[' + PyStr(Name) + '](' + Subject;
  if Args <> '' then
    Result := Result + ', ' + Args;
  Result := Result + ')';
end;

function TExprTranslator.SafeSubject(const E: string): string;
begin
  case FShape of
    shGlobal: Result := '_globals.get(' + PyStr(FShapeKey) + ', UNDEFINED)';
    shAttr: Result := 'getattr_(' + FShapeObj + ', ' + FShapeKey + ', UNDEFINED)';
    shItem: Result := 'getitem(' + FShapeObj + ', ' + FShapeKey + ', UNDEFINED)';
  else
    Result := E;
  end;
end;

function TExprTranslator.ParseFilterExpr(const E: string): string;
var
  Name, Args, Test, Arg: string;
  Negate, HasArgs: Boolean;
  P: Integer;
  Shape: TShape;
  ShapeObj, ShapeKey: string;
begin
  Result := E;
  while True do
  begin
    if IsOp('|') then
    begin
      Next;
      P := FTokPos;
      if FTokKind <> xkName then
        Fail(P, 'Expected a filter name after `|`');
      Name := FTokVal;
      Next;
      while IsOp('.') do
      begin
        Next;
        Name := Name + '.' + FTokVal;
        Next;
      end;
      if (Name = 'default') or (Name = 'd') then
        Result := SafeSubject(Result);
      FShape := shOther;
      if not ParseCallArgs(Args) then
        Args := '';
      Result := FilterCall(Name, Result, Args);
    end
    else if IsName('is') then
    begin
      Next;
      Negate := False;
      if IsName('not') then
      begin
        Negate := True;
        Next;
      end;
      P := FTokPos;
      if FTokKind <> xkName then
        Fail(P, 'Expected a test name after `is`');
      Name := FTokVal;
      Next;
      Shape := FShape;
      ShapeObj := FShapeObj;
      ShapeKey := FShapeKey;
      (* argument: `(a, b)` or a single primary *)
      HasArgs := ParseCallArgs(Args);
      if not HasArgs then
      begin
        Args := '';
        if ((FTokKind in [xkName, xkStr, xkInt, xkFloat]) or IsOp('[') or IsOp('{') or IsOp('('))
          and not (IsName('else') or IsName('or') or IsName('and') or IsName('if')) then
        begin
          if IsName('is') then
            Fail(FTokPos, 'You cannot chain multiple tests with one `is`');
          Arg := ParsePrimary;
          Arg := ParsePostfix(Arg);
          Args := Arg;
          HasArgs := True;
        end;
      end;
      FShape := shOther;
      case Name of
        'defined', 'undefined':
          begin
            case Shape of
              shLocal: Test := 'True';
              shGlobal: Test := '(' + PyStr(ShapeKey) + ' in _globals)';
              shAttr: Test := 'has_attr(' + ShapeObj + ', ' + ShapeKey + ')';
              shItem: Test := 'has_attr(' + ShapeObj + ', ' + ShapeKey + ')';
            else
              Test := '(' + Result + ' is not None)';
            end;
            if Name = 'undefined' then
              Negate := not Negate;
          end;
        'none': Test := '(' + Result + ' is None)';
        'in': Test := '(' + Result + ' in ' + Args + ')';
        'callable': Test := 'callable(' + Result + ')';
        'sameas': Test := '(' + Result + ' is ' + Args + ')';
        'eq', 'equalto', '==': Test := '(' + Result + ' == ' + Args + ')';
        'ne', '!=': Test := '(' + Result + ' != ' + Args + ')';
        'gt', 'greaterthan', '>': Test := '(' + Result + ' > ' + Args + ')';
        'ge', '>=': Test := '(' + Result + ' >= ' + Args + ')';
        'lt', 'lessthan', '<': Test := '(' + Result + ' < ' + Args + ')';
        'le', '<=': Test := '(' + Result + ' <= ' + Args + ')';
      else
        Test := TestCall(Name, Result, Args);
      end;
      if Negate then
        Result := '(not ' + Test + ')'
      else
        Result := Test;
    end
    else
      Break;
  end;
end;

function TExprTranslator.TranslateTarget(out Names: TStringArray): string;
var
  N: Integer;
  Paren: Boolean;

  procedure AddName;
  begin
    if FTokKind <> xkName then
      Fail(FTokPos, 'Expected a variable name');
    if InList(FTokVal, ['in', 'if', 'and', 'or', 'not', 'is']) then
      Fail(FTokPos, '`' + FTokVal + '` cannot be a variable name');
    SetLength(Names, N + 1);
    Names[N] := FTokVal;
    Inc(N);
    Next;
  end;

begin
  N := 0;
  SetLength(Names, 0);
  Paren := IsOp('(');
  if Paren then
    Next;
  AddName;
  while IsOp(',') do
  begin
    Next;
    if IsOp(')') or IsName('in') then
      Break;
    AddName;
  end;
  if Paren then
    Expect(')');
  if N = 1 then
    Result := Names[0]
  else
  begin
    Result := '(';
    for N := 0 to High(Names) do
    begin
      if N > 0 then
        Result := Result + ', ';
      Result := Result + Names[N];
    end;
    Result := Result + ')';
  end;
end;

procedure TExprTranslator.TranslateFor(out Target: string; out Names: TStringArray;
  out Iter: string; out Cond: string; out Recursive: Boolean; IterScope: TScope);
var
  BodyScope: TScope;
  i: Integer;
begin
  Target := TranslateTarget(Names);
  if not IsName('in') then
    Fail(FTokPos, 'Expected `in`');
  Next;
  (* the iterable is resolved in the enclosing scope *)
  FScope := IterScope;
  Iter := ParseOr; (* no inline-if here, like Jinja *)
  Cond := '';
  Recursive := False;
  if IsName('if') then
  begin
    Next;
    BodyScope := TScope.Create(IterScope);
    try
      for i := 0 to High(Names) do
        BodyScope.Add(Names[i]);
      FScope := BodyScope;
      Cond := ParseExpression;
    finally
      FScope := IterScope;
      BodyScope.Free;
    end;
  end;
  if IsName('recursive') then
  begin
    Next;
    Recursive := True;
  end;
  if FTokKind <> xkEOF then
    Fail(FTokPos, 'Unexpected `' + FTokVal + '` in for statement');
end;

procedure TExprTranslator.TranslateSet(out Name: string; out Value: string);
begin
  if FTokKind <> xkName then
    Fail(FTokPos, 'Expected a variable name after `set`');
  Name := FTokVal;
  Next;
  if IsOp(',') or IsOp('.') or IsOp('[') then
    Fail(FTokPos, 'minijx only supports `{% set name = value %}`');
  Expect('=');
  Value := ParseExpression;
  if FTokKind <> xkEOF then
    Fail(FTokPos, 'Unexpected `' + FTokVal + '` in set statement');
end;

(* `upper|replace("a", "b")` applied to Subject (a Python expression). *)
function TExprTranslator.TranslateFilterChain(const Subject: string): string;
var
  Name, Args: string;
begin
  Result := Subject;
  FShape := shOther;
  while True do
  begin
    if FTokKind <> xkName then
      Fail(FTokPos, 'Expected a filter name');
    Name := FTokVal;
    Next;
    if not ParseCallArgs(Args) then
      Args := '';
    Result := FilterCall(Name, Result, Args);
    if IsOp('|') then
      Next
    else
      Break;
  end;
  if FTokKind <> xkEOF then
    Fail(FTokPos, 'Unexpected `' + FTokVal + '` in filter statement');
end;

(* `{% call fn %}` -> `fn(Body)`; `{% call obj.fn(1, x=2) %}` ->
   `getattr_(obj, 'fn')(Body, 1, x=2)`. Like `{% filter %}`, but the
   callable is a variable, and the rendered body goes first. *)
function TExprTranslator.TranslateCallBlock(const Body: string): string;
var
  E: string;
  P: Integer;
begin
  P := FTokPos;
  if FTokKind = xkEOF then
    Fail(P, '`{% call %}` needs something to call');
  FLastCallee := '';
  FLastArgs := '';
  E := ParsePrimary;
  E := ParsePostfix(E);
  if FTokKind <> xkEOF then
    Fail(FTokPos, 'Unexpected `' + FTokVal + '` in call statement; expected `name` or `name(args)`');
  if (FLastCallee <> '') and (E = FLastCallee + '(' + FLastArgs + ')') then
  begin
    if FLastArgs <> '' then
      Result := FLastCallee + '(' + Body + ', ' + FLastArgs + ')'
    else
      Result := FLastCallee + '(' + Body + ')';
  end
  else
    Result := E + '(' + Body + ')';
end;

end.
