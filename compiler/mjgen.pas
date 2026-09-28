(* minijx: one component's template -> one Python function.

  The function appends pieces of text to a list `_b` (through `_a`, its
  bound `append`) and returns them joined. Blocks whose surrounding code
  depends on what they contain (a for loop needs a Loop object only when
  its body uses `loop`; the function needs the filter dict only when its
  body uses a filter) are generated into their own TWriter first. *)
unit mjgen;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, mjerrors, mjutil, mjlexer, mjparser, mjexpr, mjcomponent;

type
  TFuncGen = class
  private
    FComp: TComponent;
    FDoc: TDocument;
    FCounter: PInteger; (* shared by the module, so names never clash *)
    FUsesFilters: Boolean;
    FUsesTests: Boolean;
    function NextId: string;
    function NewTranslator(const Src: string; Pos: Integer; Scope: TScope): TExprTranslator;
    procedure Absorb(T: TExprTranslator);
    function Expr(const Src: string; Pos: Integer; Scope: TScope): string;
    procedure EmitNodes(W: TWriter; L: TNodeList; Scope: TScope; const App: string);
    procedure EmitBody(W: TWriter; L: TNodeList; Scope: TScope; const App: string);
    procedure EmitBuffer(W: TWriter; const Id: string; L: TNodeList; Scope: TScope);
    procedure EmitIf(W: TWriter; N: TNode; Scope: TScope; const App: string);
    procedure EmitFor(W: TWriter; N: TNode; Scope: TScope; const App: string);
    procedure EmitFilter(W: TWriter; N: TNode; Scope: TScope; const App: string);
    procedure EmitCall(W: TWriter; N: TNode; Scope: TScope; const App: string);
    procedure EmitSlot(W: TWriter; N: TNode; Scope: TScope; const App: string);
    procedure EmitComponent(W: TWriter; N: TNode; Scope: TScope; const App: string);
  public
    constructor Create(AComp: TComponent; ACounter: PInteger);
    (* the Python function, `def <FuncName>(...)` *)
    function Generate: string;
  end;

implementation

constructor TFuncGen.Create(AComp: TComponent; ACounter: PInteger);
begin
  FComp := AComp;
  FDoc := AComp.Doc;
  FCounter := ACounter;
end;

function TFuncGen.NextId: string;
begin
  Inc(FCounter^);
  Result := IntToStr(FCounter^);
end;

function TFuncGen.NewTranslator(const Src: string; Pos: Integer; Scope: TScope): TExprTranslator;
begin
  Result := TExprTranslator.Create(FDoc.FileName, FDoc.Source, Src, Pos, Scope);
end;

(* What a translated expression needs from the function around it. (`loop`
   is marked on its scope by the translator itself.) *)
procedure TFuncGen.Absorb(T: TExprTranslator);
begin
  FUsesFilters := FUsesFilters or T.UsesFilters;
  FUsesTests := FUsesTests or T.UsesTests;
end;

function TFuncGen.Expr(const Src: string; Pos: Integer; Scope: TScope): string;
var
  T: TExprTranslator;
begin
  T := NewTranslator(Src, Pos, Scope);
  try
    Result := T.Translate;
    Absorb(T);
  finally
    T.Free;
  end;
end;

(* Text for a Python f-string: its literal part, with braces doubled. *)
function FStringText(const S: string): string;
var
  i: Integer;
  B: TBuf;
begin
  B := TBuf.Create;
  try
    for i := 1 to Length(S) do
      case S[i] of
        '{': B.Add('{{');
        '}': B.Add('}}');
        '\': B.Add('\\');
        '''': B.Add('\''');
        #10: B.Add('\n');
        #13: B.Add('\r');
        #9: B.Add('\t');
        #0..#8, #11, #12, #14..#31: B.Add('\x' + IntToHex(Ord(S[i]), 2));
      else
        B.Add(S[i]);
      end;
    Result := B.Join;
  finally
    B.Free;
  end;
end;

procedure TFuncGen.EmitNodes(W: TWriter; L: TNodeList; Scope: TScope; const App: string);
var
  i: Integer;
  N: TNode;
  T: TExprTranslator;
  Name, Value: string;
  (* consecutive text and `{{ }}` outputs, written with one append *)
  Run: TStringArray;    (* text, or Python expression *)
  RunIsExpr: array of Boolean;
  Text: string;         (* text not added to Run yet *)

  procedure AddText;
  begin
    if Text = '' then
      Exit;
    SetLength(Run, Length(Run) + 1);
    SetLength(RunIsExpr, Length(RunIsExpr) + 1);
    Run[High(Run)] := Text;
    RunIsExpr[High(RunIsExpr)] := False;
    Text := '';
  end;

  procedure AddExpr(const E: string);
  begin
    AddText;
    SetLength(Run, Length(Run) + 1);
    SetLength(RunIsExpr, Length(RunIsExpr) + 1);
    Run[High(Run)] := E;
    RunIsExpr[High(RunIsExpr)] := True;
  end;

  (* One piece: `_a('text')` or `_a(_s(expr))`. More: an f-string, which
     builds the text in one go instead of one call per piece; `!s` is the
     same str() the single case uses. *)
  procedure FlushRun;
  var
    k: Integer;
    F: string;
  begin
    AddText;
    if Length(Run) = 1 then
    begin
      if RunIsExpr[0] then
        W.Line(App + '(_s(' + Run[0] + '))')
      else
        W.Line(App + '(' + PyStr(Run[0]) + ')');
    end
    else if Length(Run) > 1 then
    begin
      F := '';
      for k := 0 to High(Run) do
        if RunIsExpr[k] then
          F := F + '{(' + Run[k] + ')!s}'
        else
          F := F + FStringText(Run[k]);
      W.Line(App + '(f''' + F + ''')');
    end;
    SetLength(Run, 0);
    SetLength(RunIsExpr, 0);
  end;

begin
  Text := '';
  SetLength(Run, 0);
  SetLength(RunIsExpr, 0);
  for i := 0 to L.Count - 1 do
  begin
    N := L[i];
    case N.Kind of
      nkText, nkRaw:
        begin
          Text := Text + N.Text;
          Continue;
        end;
      nkOutput:
        begin
          AddExpr(Expr(N.Expr, N.ExprPos, Scope));
          Continue;
        end;
      nkComment:
        Continue;
    end;
    FlushRun;
    case N.Kind of
      nkIf:
        EmitIf(W, N, Scope, App);
      nkFor:
        EmitFor(W, N, Scope, App);
      nkSet:
        begin
          T := NewTranslator(N.Expr, N.ExprPos, Scope);
          try
            T.TranslateSet(Name, Value);
            Absorb(T);
          finally
            T.Free;
          end;
          W.Line(Name + ' = ' + Value);
          Scope.Add(Name);
        end;
      nkDo:
        W.Line(Expr(N.Expr, N.ExprPos, Scope));
      nkFilter:
        EmitFilter(W, N, Scope, App);
      nkCall:
        EmitCall(W, N, Scope, App);
      nkSlot:
        EmitSlot(W, N, Scope, App);
      nkComponent:
        EmitComponent(W, N, Scope, App);
      nkFill:
        CompileError(FDoc.FileName, FDoc.Source, N.Pos, 'Unexpected `{% fill %}`');
    end;
  end;
  FlushRun;
end;

(* The body of a Python block. A body can have nodes and still produce no
   code (comments, text trimmed away by whitespace control), and an empty
   Python block is a syntax error, hence the `pass`. *)
procedure TFuncGen.EmitBody(W: TWriter; L: TNodeList; Scope: TScope; const App: string);
var
  Before: Integer;
begin
  Before := W.Count;
  EmitNodes(W, L, Scope, App);
  if W.Count = Before then
    W.Line('pass');
end;

(* `_b<id> = []; _a<id> = _b<id>.append; <nodes>`: a list of its own, for a
   block whose rendered text is used as a value. *)
procedure TFuncGen.EmitBuffer(W: TWriter; const Id: string; L: TNodeList; Scope: TScope);
begin
  W.Line('_b' + Id + ' = []');
  W.Line('_a' + Id + ' = _b' + Id + '.append');
  EmitNodes(W, L, Scope, '_a' + Id);
end;

procedure TFuncGen.EmitIf(W: TWriter; N: TNode; Scope: TScope; const App: string);
var
  i: Integer;
  B: TBranch;
begin
  for i := 0 to High(N.Branches) do
  begin
    B := N.Branches[i];
    if B.Cond = '' then
      W.Line('else:')
    else if i = 0 then
      W.Line('if ' + Expr(B.Cond, B.CondPos, Scope) + ':')
    else
      W.Line('elif ' + Expr(B.Cond, B.CondPos, Scope) + ':');
    Inc(W.Indent);
    EmitBody(W, B.Body, Scope, App);
    Dec(W.Indent);
  end;
end;

procedure TFuncGen.EmitFor(W: TWriter; N: TNode; Scope: TScope; const App: string);
var
  T: TExprTranslator;
  Target, Iter, Cond, Id, IterExpr, LoopVar, ElseFlag, BodyApp: string;
  Names: TStringArray;
  Recursive, HasElse: Boolean;
  BodyScope: TScope;
  i, Depth: Integer;
  BodyW, ElseW: TWriter;
begin
  Id := NextId;
  T := NewTranslator(N.Expr, N.ExprPos, Scope);
  try
    T.TranslateFor(Target, Names, Iter, Cond, Recursive, Scope);
    Absorb(T);
  finally
    T.Free;
  end;
  HasElse := (N.ElseBody <> nil) and (N.ElseBody.Count > 0);
  LoopVar := '_l' + Id;
  ElseFlag := '_e' + Id;
  (* a recursive loop is a nested function that appends to a list of its own *)
  if Recursive then
  begin
    Depth := 2;
    BodyApp := '_ra' + Id;
  end
  else
  begin
    Depth := 1;
    BodyApp := App;
  end;

  BodyScope := TScope.Create(Scope);
  BodyW := TWriter.Create(W.Indent + Depth);
  ElseW := TWriter.Create(W.Indent + Depth);
  try
    for i := 0 to High(Names) do
      BodyScope.Add(Names[i]);
    BodyScope.LoopVar := LoopVar;

    (* the body first: it tells whether the loop needs a Loop object *)
    if HasElse then
      BodyW.Line(ElseFlag + ' = False');
    EmitBody(BodyW, N.Body, BodyScope, BodyApp);
    if HasElse then
      EmitBody(ElseW, N.ElseBody, Scope, BodyApp);

    if Cond <> '' then
      IterExpr := '(' + Target + ' for ' + Target + ' in ' + Iter + ' if ' + Cond + ')'
    else
      IterExpr := Iter;

    if Recursive then
    begin
      W.Line('def _r' + Id + '(_iter, _depth0=0):');
      Inc(W.Indent);
      W.Line('_rb' + Id + ' = []');
      W.Line('_ra' + Id + ' = _rb' + Id + '.append');
      if Cond <> '' then
        W.Line(LoopVar + ' = Loop((' + Target + ' for ' + Target + ' in _iter if ' + Cond +
          '), _depth0, _r' + Id + ')')
      else
        W.Line(LoopVar + ' = Loop(_iter, _depth0, _r' + Id + ')');
      if HasElse then
        W.Line(ElseFlag + ' = True');
    end
    else
    begin
      if HasElse then
        W.Line(ElseFlag + ' = True');
      if BodyScope.LoopUsed then
        W.Line(LoopVar + ' = Loop(' + IterExpr + ')');
    end;
    if Recursive or BodyScope.LoopUsed then
      W.Line('for ' + Target + ' in ' + LoopVar + ':')
    else
      W.Line('for ' + Target + ' in ' + IterExpr + ':');
    W.Append(BodyW);
    if HasElse then
    begin
      W.Line('if ' + ElseFlag + ':');
      W.Append(ElseW);
    end;
    if Recursive then
    begin
      W.Line('return "".join(_rb' + Id + ')');
      Dec(W.Indent);
      W.Line(App + '(_r' + Id + '(' + Iter + '))');
    end;
  finally
    ElseW.Free;
    BodyW.Free;
    BodyScope.Free;
  end;
end;

procedure TFuncGen.EmitFilter(W: TWriter; N: TNode; Scope: TScope; const App: string);
var
  Id, Chain: string;
  T: TExprTranslator;
begin
  Id := NextId;
  EmitBuffer(W, Id, N.Body, Scope);
  T := NewTranslator(N.Expr, N.ExprPos, Scope);
  try
    Chain := T.TranslateFilterChain('"".join(_b' + Id + ')');
    Absorb(T);
  finally
    T.Free;
  end;
  W.Line(App + '(_s(' + Chain + '))');
end;

procedure TFuncGen.EmitCall(W: TWriter; N: TNode; Scope: TScope; const App: string);
var
  Id, Call: string;
  T: TExprTranslator;
begin
  Id := NextId;
  EmitBuffer(W, Id, N.Body, Scope);
  T := NewTranslator(N.Expr, N.ExprPos, Scope);
  try
    Call := T.TranslateCallBlock('"".join(_b' + Id + ')');
    Absorb(T);
  finally
    T.Free;
  end;
  W.Line(App + '(_s(' + Call + '))');
end;

procedure TFuncGen.EmitSlot(W: TWriter; N: TNode; Scope: TScope; const App: string);
begin
  W.Line('if ' + PyStr(N.Name) + ' in _fills:');
  Inc(W.Indent);
  W.Line(App + '(_fills[' + PyStr(N.Name) + ']())');
  Dec(W.Indent);
  if N.Body.Count > 0 then
  begin
    W.Line('else:');
    Inc(W.Indent);
    EmitBody(W, N.Body, Scope, App);
    Dec(W.Indent);
  end;
end;

procedure TFuncGen.EmitComponent(W: TWriter; N: TNode; Scope: TScope; const App: string);
var
  Dep: TComponent;
  i: Integer;
  A: TAttr;
  Args, Kw, Fills, Call, Id, FillId, Name, Value: string;
  FillScope: TScope;
  F: TNode;
  HasContent, Plain: Boolean;
begin
  Dep := FComp.FindDep(N.Name);
  if Dep = nil then
    CompileError(FDoc.FileName, FDoc.Source, N.Pos,
      'Component `' + N.Name + '` is not imported; add `{# import "..." as ' + N.Name + ' #}`');

  Id := NextId;
  (* fills become closures defined before the call, rendered only if the
     component reaches the slot *)
  Fills := '';
  for i := 0 to N.Fills.Count - 1 do
  begin
    F := N.Fills[i];
    FillId := NextId;
    W.Line('def _fill' + FillId + '():');
    Inc(W.Indent);
    FillScope := TScope.Create(Scope);
    try
      EmitBuffer(W, FillId, F.Body, FillScope);
    finally
      FillScope.Free;
    end;
    W.Line('return "".join(_b' + FillId + ')');
    Dec(W.Indent);
    Fills := Fills + PyStr(F.Name) + ': _fill' + FillId + ', ';
  end;

  (* the default content, rendered eagerly into its own list *)
  HasContent := N.Body.HasContent;
  if HasContent then
    EmitBuffer(W, Id, N.Body, Scope);

  (* Attributes go as plain keyword arguments, much cheaper than building
     and unpacking a dict. Names Python cannot take that way (`class`,
     `@click`) go in a `**{...}`, and so does everything when one of them is
     a name the function itself uses, to keep what that does as it was. (The
     lexer already refused repeated names.) *)
  Plain := True;
  for i := 0 to High(N.Attrs) do
    if InList(ReplaceChar(N.Attrs[i].Name, '-', '_'), ['content', '_globals', '_fills']) then
      Plain := False;
  Args := '';
  Kw := '';
  for i := 0 to High(N.Attrs) do
  begin
    A := N.Attrs[i];
    Name := ReplaceChar(A.Name, '-', '_');
    case A.Kind of
      akFlag: Value := 'True';
      akString: Value := A.Value;
    else
      Value := Expr(A.Value, A.ValuePos, Scope);
    end;
    if Plain and IsPyIdentifier(Name) then
      Args := Args + Name + '=' + Value + ', '
    else
      Kw := Kw + PyStr(Name) + ': ' + Value + ', ';
  end;

  Call := Dep.FuncName + '(' + Args;
  if Kw <> '' then
    Call := Call + '**{' + Copy(Kw, 1, Length(Kw) - 2) + '}, ';
  if HasContent then
    Call := Call + 'content="".join(_b' + Id + '), ';
  if Fills <> '' then
    Call := Call + '_fills={' + Copy(Fills, 1, Length(Fills) - 2) + '}, ';
  Call := Call + '_globals=_globals)';
  W.Line(App + '(' + Call + ')');
end;

function TFuncGen.Generate: string;
var
  Scope: TScope;
  Sig: string;
  i: Integer;
  HasContentArg, HasAttrsArg: Boolean;
  W, BodyW: TWriter;
begin
  Scope := TScope.Create(nil);
  W := TWriter.Create(0);
  BodyW := TWriter.Create(1);
  try
    Sig := '*';
    HasContentArg := False;
    HasAttrsArg := False;
    for i := 0 to High(FComp.Args) do
    begin
      Sig := Sig + ', ' + FComp.Args[i].Name;
      if FComp.Args[i].Annotation <> '' then
        Sig := Sig + ': ' + FComp.Args[i].Annotation;
      if FComp.Args[i].HasDefault then
        Sig := Sig + '=' + FComp.Args[i].Default;
      Scope.Add(FComp.Args[i].Name);
      HasContentArg := HasContentArg or (FComp.Args[i].Name = 'content');
      HasAttrsArg := HasAttrsArg or (FComp.Args[i].Name = 'attrs');
    end;
    if not HasContentArg then
      Sig := Sig + ', content=""';
    Sig := Sig + ', _globals=None, _fills=None, **_extra';
    Scope.Add('content');
    Scope.Add('attrs');
    Scope.Add('_globals');
    Scope.Add('_fills');

    (* the body first: it tells whether the function needs the filters and
       tests *)
    BodyW.Line('_b = []');
    BodyW.Line('_a = _b.append');
    EmitNodes(BodyW, FDoc.Body, Scope, '_a');
    (* like Jx's Component.render: the output never starts with whitespace *)
    BodyW.Line('return "".join(_b).lstrip()');

    W.Line('def ' + FComp.FuncName + '(' + Sig + '):');
    Inc(W.Indent);
    W.Line('if _globals is None:');
    W.Line('    _globals = {}');
    W.Line('if _fills is None:');
    W.Line('    _fills = {}');
    if FComp.UsesAttrs and not HasAttrsArg then
      W.Line('attrs = _extra["attrs"] if isinstance(_extra.get("attrs"), Attrs) else Attrs(_extra)');
    (* custom filters and tests come from the catalog, through `_globals` *)
    if FUsesFilters then
      W.Line('_f = _globals.get("__minijx_filters__", _FILTERS)');
    if FUsesTests then
      W.Line('_t = _globals.get("__minijx_tests__", _TESTS)');
    W.Append(BodyW);
    Result := W.Text;
  finally
    BodyW.Free;
    W.Free;
    Scope.Free;
  end;
end;

end.
