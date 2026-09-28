(* minijx: Python code generator and import resolver.

  A TCompiler loads .jx files, resolves their `{# import #}` declarations
  against the root folders, and emits one Python module per file. Every
  component the file depends on (transitively) is copied into that module as
  a private function, so the module only imports the minijx runtime. *)
unit mjcodegen;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, StrUtils, mjerrors, mjutil, mjlexer, mjexpr, mjparser;

type
  TComponent = class;

  TDep = record
    Alias: string;
    Comp: TComponent;
  end;

  TArg = record
    Name: string;
    Annotation: string;
    Default: string; (* Python source; '' if required *)
    HasDefault: Boolean;
  end;

  TComponent = class
  public
    Path: string;     (* absolute *)
    RootIdx: Integer; (* the root it was resolved from *)
    FuncName: string;
    Doc: TDocument;
    Deps: array of TDep;
    Args: array of TArg;
    UsesAttrs: Boolean;
    destructor Destroy; override;
    function FindDep(const Alias: string): TComponent;
  end;

  TCompiler = class
  private
    FRoots: TStringArray; (* absolute, with a trailing separator *)
    FCache: TStringList; (* absolute path -> TComponent *)
    FNames: TStringList; (* function names already given out *)
    function ResolveImport(C: TComponent; const D: TImportDecl; out RootIdx: Integer): string;
    procedure ParseDef(C: TComponent);
    function MangledName(const Path: string; RootIdx: Integer): string;
  public
    constructor Create(const ARoots: TStringArray);
    destructor Destroy; override;
    (* Load and resolve a component and everything it imports. *)
    function Load(const Path: string; RootIdx: Integer): TComponent;
    (* The full Python module for a component. *)
    function CompileModule(C: TComponent): string;
  end;

const
  (* Version of the generated module layout; must match MODULE_FORMAT in
     python/minijx/catalog.py. 3: CSS/JS are plain URLs (2 had pairs).
     4: `|default` receives UNDEFINED, not None, for a missing value.
     5: filters and tests are looked up in dicts (`_f["name"]`), which the
        catalog can replace with its own. *)
  ModuleFormat = 5;
  (* Must match `__version__` in src/minijx/__init__.py; the wheel build
     checks it. *)
  MinijxVersion = '0.1.0';

(* `dir/sitemap.xml.jx` -> `dir/sitemap_xml.py`: the `.jx` is dropped and any
   other dot in the file name becomes `_`, so the module is importable. *)
function OutputPath(const JxPath: string): string;

implementation

function OutputPath(const JxPath: string): string;
var
  Name: string;
begin
  Name := ExtractFileName(JxPath);
  if EndsWith(Name, '.jx') then
    Delete(Name, Length(Name) - 2, 3);
  Result := ExtractFilePath(JxPath) + ReplaceChar(Name, '.', '_') + '.py';
end;

(* TComponent *)

destructor TComponent.Destroy;
begin
  Doc.Free;
  inherited;
end;

function TComponent.FindDep(const Alias: string): TComponent;
var
  i: Integer;
begin
  for i := 0 to High(Deps) do
    if Deps[i].Alias = Alias then
      Exit(Deps[i].Comp);
  Result := nil;
end;

(* Function generator ------------------------------------------------------ *)

type
  TFuncGen = class
  private
    FComp: TComponent;
    FDoc: TDocument;
    FBuf: TBuf;
    FIndent: Integer;
    FCounter: PInteger;
    FUsesFilters: Boolean;
    FUsesTests: Boolean;
    procedure Line(const S: string);
    function NextId: string;
    function Expr(const Src: string; Pos: Integer; Scope: TScope): string;
    function NewTranslator(const Src: string; Pos: Integer; Scope: TScope): TExprTranslator;
    procedure NoteLoop(T: TExprTranslator; Scope: TScope);
    procedure EmitNodes(L: TNodeList; Scope: TScope; const App: string);
    procedure EmitBody(L: TNodeList; Scope: TScope; const App: string);
    procedure EmitIf(N: TNode; Scope: TScope; const App: string);
    procedure EmitFor(N: TNode; Scope: TScope; const App: string);
    procedure EmitFilter(N: TNode; Scope: TScope; const App: string);
    procedure EmitCall(N: TNode; Scope: TScope; const App: string);
    procedure EmitSlot(N: TNode; Scope: TScope; const App: string);
    procedure EmitComponent(N: TNode; Scope: TScope; const App: string);
    procedure EmitBuffer(const Id: string; L: TNodeList; Scope: TScope);
  public
    constructor Create(AComp: TComponent; ACounter: PInteger);
    function Generate: string;
  end;

constructor TFuncGen.Create(AComp: TComponent; ACounter: PInteger);
begin
  FComp := AComp;
  FDoc := AComp.Doc;
  FCounter := ACounter;
  FBuf := TBuf.Create;
end;

procedure TFuncGen.Line(const S: string);
begin
  FBuf.Add(StrRepeat('    ', FIndent) + S + #10);
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

(* A translator that resolved `loop` marks the scope owning that loop, so the
  for statement knows to create a Loop object. *)
procedure TFuncGen.NoteLoop(T: TExprTranslator; Scope: TScope);
var
  S: TScope;
begin
  if T.UsesFilters then
    FUsesFilters := True;
  if T.UsesTests then
    FUsesTests := True;
  if not T.UsesLoop then
    Exit;
  S := Scope;
  while (S <> nil) and (S.LoopVar = '') do
    S := S.Parent;
  if S <> nil then
    S.Add('__loop_used__');
end;

function TFuncGen.Expr(const Src: string; Pos: Integer; Scope: TScope): string;
var
  T: TExprTranslator;
begin
  T := NewTranslator(Src, Pos, Scope);
  try
    Result := T.Translate;
    NoteLoop(T, Scope);
  finally
    T.Free;
  end;
end;

procedure TFuncGen.EmitNodes(L: TNodeList; Scope: TScope; const App: string);
var
  i: Integer;
  N: TNode;
  Text: string;
  T: TExprTranslator;
  Name, Value: string;

  procedure FlushText;
  begin
    if Text <> '' then
      Line(App + '(' + PyStr(Text) + ')');
    Text := '';
  end;

begin
  Text := '';
  for i := 0 to L.Count - 1 do
  begin
    N := L[i];
    if N.Kind in [nkText, nkRaw] then
    begin
      Text := Text + N.Text;
      Continue;
    end;
    if N.Kind = nkComment then
      Continue;
    FlushText;
    case N.Kind of
      nkOutput:
        Line(App + '(_s(' + Expr(N.Expr, N.ExprPos, Scope) + '))');
      nkIf:
        EmitIf(N, Scope, App);
      nkFor:
        EmitFor(N, Scope, App);
      nkSet:
        begin
          T := NewTranslator(N.Expr, N.ExprPos, Scope);
          try
            T.TranslateSet(Name, Value);
            NoteLoop(T, Scope);
          finally
            T.Free;
          end;
          Line(Name + ' = ' + Value);
          Scope.Add(Name);
        end;
      nkDo:
        Line(Expr(N.Expr, N.ExprPos, Scope));
      nkFilter:
        EmitFilter(N, Scope, App);
      nkCall:
        EmitCall(N, Scope, App);
      nkSlot:
        EmitSlot(N, Scope, App);
      nkComponent:
        EmitComponent(N, Scope, App);
      nkFill:
        CompileError(FDoc.FileName, FDoc.Source, N.Pos, 'Unexpected `{% fill %}`');
      nkText, nkRaw, nkComment: ;
    end;
  end;
  FlushText;
end;

(* The body of a Python block. A body can have nodes and still produce no
   code (comments, text trimmed away by whitespace control), and an empty
   Python block is a syntax error, hence the `pass`. *)
procedure TFuncGen.EmitBody(L: TNodeList; Scope: TScope; const App: string);
var
  Before: Integer;
begin
  Before := FBuf.Count;
  EmitNodes(L, Scope, App);
  if FBuf.Count = Before then
    Line('pass');
end;

procedure TFuncGen.EmitIf(N: TNode; Scope: TScope; const App: string);
var
  i: Integer;
  B: TBranch;
  Cond: string;
begin
  for i := 0 to High(N.Branches) do
  begin
    B := N.Branches[i];
    if B.Cond = '' then
      Line('else:')
    else
    begin
      Cond := Expr(B.Cond, B.CondPos, Scope);
      if i = 0 then
        Line('if ' + Cond + ':')
      else
        Line('elif ' + Cond + ':');
    end;
    Inc(FIndent);
    EmitBody(B.Body, Scope, App);
    Dec(FIndent);
  end;
end;

procedure TFuncGen.EmitFor(N: TNode; Scope: TScope; const App: string);
var
  T: TExprTranslator;
  Target, Iter, Cond, Id, IterExpr, LoopVar, ElseFlag, BodyApp: string;
  Names: TStringArray;
  Recursive, LoopUsed, HasElse: Boolean;
  BodyScope: TScope;
  i: Integer;
  SaveBuf, BodyBuf, ElseBuf: TBuf;
  SaveIndent: Integer;
begin
  Id := NextId;
  T := NewTranslator(N.Expr, N.ExprPos, Scope);
  try
    T.TranslateFor(Target, Names, Iter, Cond, Recursive, Scope);
    NoteLoop(T, Scope);
  finally
    T.Free;
  end;
  HasElse := (N.ElseBody <> nil) and (N.ElseBody.Count > 0);
  LoopVar := '_l' + Id;
  ElseFlag := '_e' + Id;

  BodyScope := TScope.Create(Scope);
  try
    for i := 0 to High(Names) do
      BodyScope.Add(Names[i]);
    BodyScope.LoopVar := LoopVar;

    (* the body first, into its own buffer, to learn whether it uses `loop` *)
    SaveBuf := FBuf;
    SaveIndent := FIndent;
    BodyBuf := TBuf.Create;
    FBuf := BodyBuf;
    if Recursive then
    begin
      FIndent := SaveIndent + 2;
      BodyApp := '_ra' + Id;
    end
    else
    begin
      FIndent := SaveIndent + 1;
      BodyApp := App;
    end;
    if HasElse then
      Line(ElseFlag + ' = False');
    EmitBody(N.Body, BodyScope, BodyApp);
    ElseBuf := nil;
    if HasElse then
    begin
      ElseBuf := TBuf.Create;
      FBuf := ElseBuf;
      EmitBody(N.ElseBody, Scope, BodyApp);
    end;
    FBuf := SaveBuf;
    FIndent := SaveIndent;
    LoopUsed := BodyScope.IsLocal('__loop_used__') or Recursive;

    if Cond <> '' then
      IterExpr := '(' + Target + ' for ' + Target + ' in ' + Iter + ' if ' + Cond + ')'
    else
      IterExpr := Iter;

    if Recursive then
    begin
      Line('def _r' + Id + '(_iter, _depth0=0):');
      Inc(FIndent);
      Line('_rb' + Id + ' = []');
      Line('_ra' + Id + ' = _rb' + Id + '.append');
      if Cond <> '' then
        Line(LoopVar + ' = Loop((' + Target + ' for ' + Target + ' in _iter if ' + Cond + '), _depth0, _r' + Id + ')')
      else
        Line(LoopVar + ' = Loop(_iter, _depth0, _r' + Id + ')');
      if HasElse then
        Line(ElseFlag + ' = True');
      Line('for ' + Target + ' in ' + LoopVar + ':');
      FBuf.Add(BodyBuf.Join);
      if HasElse then
      begin
        Line('if ' + ElseFlag + ':');
        FBuf.Add(ElseBuf.Join);
      end;
      Line('return "".join(_rb' + Id + ')');
      Dec(FIndent);
      Line(App + '(_r' + Id + '(' + Iter + '))');
    end
    else
    begin
      if HasElse then
        Line(ElseFlag + ' = True');
      if LoopUsed then
      begin
        Line(LoopVar + ' = Loop(' + IterExpr + ')');
        Line('for ' + Target + ' in ' + LoopVar + ':');
      end
      else
        Line('for ' + Target + ' in ' + IterExpr + ':');
      FBuf.Add(BodyBuf.Join);
      if HasElse then
      begin
        Line('if ' + ElseFlag + ':');
        FBuf.Add(ElseBuf.Join);
      end;
    end;
    BodyBuf.Free;
    ElseBuf.Free;
  finally
    BodyScope.Free;
  end;
end;

(* `_b<id> = []; _a<id> = _b<id>.append; <nodes>` in the current scope. *)
procedure TFuncGen.EmitBuffer(const Id: string; L: TNodeList; Scope: TScope);
begin
  Line('_b' + Id + ' = []');
  Line('_a' + Id + ' = _b' + Id + '.append');
  EmitNodes(L, Scope, '_a' + Id);
end;

procedure TFuncGen.EmitFilter(N: TNode; Scope: TScope; const App: string);
var
  Id, Chain: string;
  T: TExprTranslator;
begin
  Id := NextId;
  EmitBuffer(Id, N.Body, Scope);
  T := NewTranslator(N.Expr, N.ExprPos, Scope);
  try
    Chain := T.TranslateFilterChain('"".join(_b' + Id + ')');
    NoteLoop(T, Scope);
  finally
    T.Free;
  end;
  Line(App + '(_s(' + Chain + '))');
end;

procedure TFuncGen.EmitCall(N: TNode; Scope: TScope; const App: string);
var
  Id, Call: string;
  T: TExprTranslator;
begin
  Id := NextId;
  EmitBuffer(Id, N.Body, Scope);
  T := NewTranslator(N.Expr, N.ExprPos, Scope);
  try
    Call := T.TranslateCallBlock('"".join(_b' + Id + ')');
    NoteLoop(T, Scope);
  finally
    T.Free;
  end;
  Line(App + '(_s(' + Call + '))');
end;

procedure TFuncGen.EmitSlot(N: TNode; Scope: TScope; const App: string);
begin
  Line('if ' + PyStr(N.Name) + ' in _fills:');
  Inc(FIndent);
  Line(App + '(_fills[' + PyStr(N.Name) + ']())');
  Dec(FIndent);
  if N.Body.Count > 0 then
  begin
    Line('else:');
    Inc(FIndent);
    EmitBody(N.Body, Scope, App);
    Dec(FIndent);
  end;
end;

procedure TFuncGen.EmitComponent(N: TNode; Scope: TScope; const App: string);
var
  Dep: TComponent;
  i: Integer;
  A: TAttr;
  Kw, Fills, Call, Id, FillId, Name: string;
  FillScope: TScope;
  F: TNode;
  HasContent: Boolean;
begin
  Dep := FComp.FindDep(N.Name);
  if Dep = nil then
    CompileError(FDoc.FileName, FDoc.Source, N.Pos,
      'Component `' + N.Name + '` is not imported; add `{# import "..." as ' + N.Name + ' #}`');

  Id := NextId;
  (* fills become closures defined before the call *)
  Fills := '';
  for i := 0 to N.Fills.Count - 1 do
  begin
    F := N.Fills[i];
    FillId := NextId;
    Line('def _fill' + FillId + '():');
    Inc(FIndent);
    FillScope := TScope.Create(Scope);
    try
      EmitBuffer(FillId, F.Body, FillScope);
    finally
      FillScope.Free;
    end;
    Line('return "".join(_b' + FillId + ')');
    Dec(FIndent);
    Fills := Fills + PyStr(F.Name) + ': _fill' + FillId + ', ';
  end;

  (* default content, rendered eagerly into its own buffer *)
  HasContent := N.Body.HasContent;
  if HasContent then
    EmitBuffer(Id, N.Body, Scope);

  Kw := '';
  for i := 0 to High(N.Attrs) do
  begin
    A := N.Attrs[i];
    Name := ReplaceChar(A.Name, '-', '_');
    case A.Kind of
      akFlag: Kw := Kw + PyStr(Name) + ': True, ';
      akString: Kw := Kw + PyStr(Name) + ': ' + A.Value + ', ';
      akExpr: Kw := Kw + PyStr(Name) + ': ' + Expr(A.Value, A.ValuePos, Scope) + ', ';
    end;
  end;

  Call := Dep.FuncName + '(';
  if Kw <> '' then
    Call := Call + '**{' + Copy(Kw, 1, Length(Kw) - 2) + '}, ';
  if HasContent then
    Call := Call + 'content="".join(_b' + Id + '), ';
  if Fills <> '' then
    Call := Call + '_fills={' + Copy(Fills, 1, Length(Fills) - 2) + '}, ';
  Call := Call + '_globals=_globals)';
  Line(App + '(' + Call + ')');
end;

function TFuncGen.Generate: string;
var
  Scope: TScope;
  Sig, Body: string;
  Head: TBuf;
  i: Integer;
  HasContentArg, HasAttrsArg: Boolean;
begin
  FBuf.Clear;
  FIndent := 0;
  Scope := TScope.Create(nil);
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
      if FComp.Args[i].Name = 'content' then
        HasContentArg := True;
      if FComp.Args[i].Name = 'attrs' then
        HasAttrsArg := True;
    end;
    if not HasContentArg then
      Sig := Sig + ', content=""';
    Sig := Sig + ', _globals=None, _fills=None, **_extra';
    Line('def ' + FComp.FuncName + '(' + Sig + '):');
    Inc(FIndent);
    Line('if _globals is None:');
    Line('    _globals = {}');
    Line('if _fills is None:');
    Line('    _fills = {}');
    if FComp.UsesAttrs and not HasAttrsArg then
      Line('attrs = _extra["attrs"] if isinstance(_extra.get("attrs"), Attrs) else Attrs(_extra)');
    Scope.Add('content');
    Scope.Add('attrs');
    Scope.Add('_globals');
    Scope.Add('_fills');
    (* the body first, to learn whether it needs the filters and tests *)
    Head := FBuf;
    FBuf := TBuf.Create;
    try
      Line('_b = []');
      Line('_a = _b.append');
      EmitNodes(FDoc.Body, Scope, '_a');
      (* like Jx's Component.render: the output never starts with whitespace *)
      Line('return "".join(_b).lstrip()');
      Body := FBuf.Join;
    finally
      FBuf.Free;
      FBuf := Head;
    end;
    (* custom filters and tests come from the catalog, through `_globals` *)
    if FUsesFilters then
      Line('_f = _globals.get("__minijx_filters__", _FILTERS)');
    if FUsesTests then
      Line('_t = _globals.get("__minijx_tests__", _TESTS)');
    FBuf.Add(Body);
    Dec(FIndent);
  finally
    Scope.Free;
  end;
  Result := FBuf.Join;
end;

(* TCompiler --------------------------------------------------------------- *)

constructor TCompiler.Create(const ARoots: TStringArray);
var
  i: Integer;
begin
  SetLength(FRoots, Length(ARoots));
  for i := 0 to High(ARoots) do
    FRoots[i] := IncludeTrailingPathDelimiter(ExpandFileName(ARoots[i]));
  FCache := TStringList.Create;
  FCache.Sorted := True;
  FCache.CaseSensitive := True;
  FNames := TStringList.Create;
  FNames.Sorted := True;
  FNames.CaseSensitive := True;
end;

destructor TCompiler.Destroy;
var
  i: Integer;
begin
  for i := 0 to FCache.Count - 1 do
    FCache.Objects[i].Free;
  FCache.Free;
  FNames.Free;
  inherited;
end;

(* `_c_<rel path>`, unique across the run:
   `a/b.jx` and `a_b.jx` would both give `_c_a_b`, so the second one gets a
   numeric suffix. *)
function TCompiler.MangledName(const Path: string; RootIdx: Integer): string;
var
  Rel, Base: string;
  i, N: Integer;
begin
  Rel := Path;
  if StartsWith(Rel, FRoots[RootIdx]) then
    Delete(Rel, 1, Length(FRoots[RootIdx]));
  if EndsWith(Rel, '.jx') then
    Delete(Rel, Length(Rel) - 2, 3);
  for i := 1 to Length(Rel) do
    if not (Rel[i] in NameChars) then
      Rel[i] := '_';
  Base := '_c_' + Rel;
  Result := Base;
  N := 1;
  while FNames.IndexOf(Result) >= 0 do
  begin
    Inc(N);
    Result := Base + '_' + IntToStr(N);
  end;
  FNames.Add(Result);
end;

(* Import rules:
   - `./x.jx`, `../x.jx`: relative to the importing file; it cannot leave the
     folder the importing file was found in.
   - `x.jx`: searched in the folders, in the order given. *)
function TCompiler.ResolveImport(C: TComponent; const D: TImportDecl; out RootIdx: Integer): string;
var
  i: Integer;
  Candidate: string;
begin
  RootIdx := -1;
  if StartsWith(D.Path, '.') then
  begin
    Candidate := ExpandFileName(ExtractFilePath(C.Path) + D.Path);
    if not StartsWith(Candidate, FRoots[C.RootIdx]) then
      CompileError(C.Doc.FileName, C.Doc.Source, D.Pos,
        'Import `' + D.Path + '` goes outside of the folder ' + FRoots[C.RootIdx]);
    if not FileExists(Candidate) then
      CompileError(C.Doc.FileName, C.Doc.Source, D.Pos,
        'Cannot find `' + D.Path + '` (looked for ' + Candidate + ')');
    RootIdx := C.RootIdx;
    Exit(Candidate);
  end;
  if StartsWith(D.Path, '@') then
    CompileError(C.Doc.FileName, C.Doc.Source, D.Pos,
      'Prefixed imports (`@name/...`) are not supported by minijx');
  for i := 0 to High(FRoots) do
  begin
    Candidate := ExpandFileName(FRoots[i] + D.Path);
    if StartsWith(Candidate, FRoots[i]) and FileExists(Candidate) then
    begin
      RootIdx := i;
      Exit(Candidate);
    end;
  end;
  CompileError(C.Doc.FileName, C.Doc.Source, D.Pos,
    'Cannot find `' + D.Path + '` in any of the folders');
  Result := '';
end;

(* A `{# def #}` default, as Jx reads it: a Python expression that may only
   use literals and the names Jx allows (`len`, `max`, `min`, `pow`, `sum`,
   `true`, `false`). It is copied as is, with `true`/`false` (and `none`)
   turned into Python's. Any other name, attribute names included, is an
   error, like Jx's "Use of ... not allowed". *)
(* Index just past the string literal starting at I (0 if unclosed). *)
function SkipPyString(const Src: string; I: Integer): Integer;
var
  Quote: Char;
  L: Integer;
begin
  L := Length(Src);
  Quote := Src[I];
  if Copy(Src, I, 3) = StringOfChar(Quote, 3) then
  begin
    Result := PosEx(StringOfChar(Quote, 3), Src, I + 3);
    if Result > 0 then
      Inc(Result, 3);
    Exit;
  end;
  Inc(I);
  while (I <= L) and (Src[I] <> Quote) do
  begin
    if Src[I] = '\' then
      Inc(I);
    Inc(I);
  end;
  if I > L then
    Exit(0);
  Result := I + 1;
end;

(* Names the expression binds itself, which Jx accepts: comprehension
   variables (`for x, y in`) and lambda parameters (`lambda a, b:`). *)
procedure CollectBoundNames(const Src: string; Bound: TStringList);
var
  i, Start, L: Integer;
  Name: string;
  InFor, InLambda: Boolean;
begin
  L := Length(Src);
  InFor := False;
  InLambda := False;
  i := 1;
  while i <= L do
  begin
    if Src[i] in ['"', ''''] then
    begin
      i := SkipPyString(Src, i);
      if i = 0 then
        Exit;
      Continue;
    end;
    if InLambda and (Src[i] = ':') then
      InLambda := False;
    if Src[i] in NameStartChars then
    begin
      Start := i;
      while (i <= L) and (Src[i] in NameChars) do
        Inc(i);
      Name := Copy(Src, Start, i - Start);
      if Name = 'for' then
        InFor := True
      else if Name = 'lambda' then
        InLambda := True
      else if InFor and (Name = 'in') then
        InFor := False
      else if InFor or InLambda then
        Bound.Add(Name);
      Continue;
    end;
    Inc(i);
  end;
end;

function PythonDefault(const FileName, FileSrc, Src: string; Base: Integer): string;
var
  i, Start, L: Integer;
  Name: string;
  Bound: TStringList;
begin
  Result := '';
  L := Length(Src);
  Bound := TStringList.Create;
  try
  CollectBoundNames(Src, Bound);
  i := 1;
  while i <= L do
  begin
    if Src[i] in ['"', ''''] then
    begin
      (* a string literal, triple-quoted or not, copied untouched *)
      Start := i;
      i := SkipPyString(Src, i);
      if i = 0 then
        CompileError(FileName, FileSrc, Base + Start - 1, 'Unclosed string');
      Result := Result + Copy(Src, Start, i - Start);
    end
    else if Src[i] in NameStartChars then
    begin
      Start := i;
      while (i <= L) and (Src[i] in NameChars) do
        Inc(i);
      Name := Copy(Src, Start, i - Start);
      (* a string prefix (f"", r"", b"") is part of the literal that follows *)
      if (i <= L) and (Src[i] in ['"', '''']) and (Length(Name) <= 2) then
      begin
        Result := Result + Name;
        Continue;
      end;
      case Name of
        'true', 'True': Result := Result + 'True';
        'false', 'False': Result := Result + 'False';
        'none', 'None': Result := Result + 'None';
        'len', 'max', 'min', 'pow', 'sum',
        'if', 'else', 'and', 'or', 'not', 'in', 'is', 'for', 'lambda':
          Result := Result + Name;
      else
        if Bound.IndexOf(Name) < 0 then
          CompileError(FileName, FileSrc, Base + Start - 1,
            'Use of ' + Name + ' not allowed in the default value');
        Result := Result + Name;
      end;
    end
    else if Src[i] in DigitChars then
    begin
      (* numbers, including `1e5`, `0x1f`, `1_000`, `2j` *)
      Start := i;
      while (i <= L) and (Src[i] in NameChars + ['.']) do
      begin
        if (Src[i] in ['e', 'E']) and (i < L) and (Src[i + 1] in ['+', '-']) then
          Inc(i);
        Inc(i);
      end;
      Result := Result + Copy(Src, Start, i - Start);
    end
    else
    begin
      Result := Result + Src[i];
      Inc(i);
    end;
  end;
  Result := Trim(Result);
  if Result = '' then
    CompileError(FileName, FileSrc, Base, 'Missing default value');
  finally
    Bound.Free;
  end;
end;

(* Splits `{# def a, b: int = 1, c="x" #}` into arguments. Defaults are
  translated as expressions with names left as they are. *)
procedure TCompiler.ParseDef(C: TComponent);
var
  S: string;
  i, Depth, Start, L: Integer;
  Quote: Char;
  Parts: TStringArray;
  PartPos: array of Integer;
  N: Integer;

  procedure AddPart(A, B: Integer);
  var
    P: string;
  begin
    P := Trim(Copy(S, A, B - A));
    if P = '' then
      Exit;
    SetLength(Parts, N + 1);
    SetLength(PartPos, N + 1);
    Parts[N] := P;
    PartPos[N] := A;
    Inc(N);
  end;

  procedure ParseArg(const P: string; PPos: Integer);
  var
    j, D, NameEnd, AnnStart, AnnEnd, DefStart: Integer;
    Q: Char;
    A: TArg;
  begin
    j := 1;
    while (j <= Length(P)) and (P[j] in ['*', '/', ' ']) do
      Inc(j);
    if (j > Length(P)) then
      Exit;
    if not (P[j] in NameStartChars) then
      CompileError(C.Doc.FileName, C.Doc.Source, C.Doc.DefPos + PPos - 1 + j - 1,
        'Invalid argument name in `{# def #}`');
    NameEnd := j;
    while (NameEnd <= Length(P)) and (P[NameEnd] in NameChars) do
      Inc(NameEnd);
    A := Default(TArg);
    A.Name := Copy(P, j, NameEnd - j);
    j := NameEnd;
    while (j <= Length(P)) and (P[j] in WhitespaceChars) do
      Inc(j);
    (* annotation up to a top-level `=` *)
    D := 0;
    Q := #0;
    AnnStart := 0;
    AnnEnd := 0;
    DefStart := 0;
    if (j <= Length(P)) and (P[j] = ':') then
    begin
      AnnStart := j + 1;
      j := AnnStart;
      while j <= Length(P) do
      begin
        if Q <> #0 then
        begin
          if P[j] = '\' then
            Inc(j)
          else if P[j] = Q then
            Q := #0;
        end
        else if P[j] in ['"', ''''] then
          Q := P[j]
        else if P[j] in ['(', '[', '{'] then
          Inc(D)
        else if P[j] in [')', ']', '}'] then
          Dec(D)
        else if (P[j] = '=') and (D = 0) then
          Break;
        Inc(j);
      end;
      AnnEnd := j;
      A.Annotation := Trim(Copy(P, AnnStart, AnnEnd - AnnStart));
    end;
    if (j <= Length(P)) and (P[j] = '=') then
    begin
      DefStart := j + 1;
      A.HasDefault := True;
      A.Default := PythonDefault(C.Doc.FileName, C.Doc.Source, Copy(P, DefStart, Length(P)),
        C.Doc.DefPos + PPos - 1 + DefStart - 1);
    end
    else if j <= Length(P) then
      CompileError(C.Doc.FileName, C.Doc.Source, C.Doc.DefPos + PPos - 1 + j - 1,
        'Unexpected `' + P[j] + '` in `{# def #}`');
    SetLength(C.Args, Length(C.Args) + 1);
    C.Args[High(C.Args)] := A;
  end;

begin
  SetLength(C.Args, 0);
  if not C.Doc.HasDef then
    Exit;
  S := C.Doc.DefExpr;
  L := Length(S);
  N := 0;
  SetLength(Parts, 0);
  Depth := 0;
  Quote := #0;
  Start := 1;
  i := 1;
  while i <= L do
  begin
    if Quote <> #0 then
    begin
      if S[i] = '\' then
        Inc(i)
      else if S[i] = Quote then
        Quote := #0;
    end
    else if S[i] in ['"', ''''] then
      Quote := S[i]
    else if S[i] in ['(', '[', '{'] then
      Inc(Depth)
    else if S[i] in [')', ']', '}'] then
      Dec(Depth)
    else if (S[i] = ',') and (Depth = 0) then
    begin
      AddPart(Start, i);
      Start := i + 1;
    end;
    Inc(i);
  end;
  AddPart(Start, L + 1);
  for i := 0 to N - 1 do
    ParseArg(Parts[i], PartPos[i]);
end;

function TCompiler.Load(const Path: string; RootIdx: Integer): TComponent;
var
  Idx, i, DepRoot: Integer;
  DepPath: string;
  Src: string;
  F: TFileStream;
  C: TComponent;
  Abs: string;
begin
  Abs := ExpandFileName(Path);
  Idx := FCache.IndexOf(Abs);
  if Idx >= 0 then
    Exit(TComponent(FCache.Objects[Idx]));

  F := TFileStream.Create(Abs, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Src, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Src[1], F.Size);
  finally
    F.Free;
  end;

  C := TComponent.Create;
  C.Path := Abs;
  C.RootIdx := RootIdx;
  C.FuncName := MangledName(Abs, RootIdx);
  C.Doc := ParseDocument(Abs, Src);
  C.UsesAttrs := Pos('attrs', Src) > 0;
  (* register before resolving imports so cycles (including self-imports) end *)
  FCache.AddObject(Abs, C);
  try
    ParseDef(C);
    SetLength(C.Deps, Length(C.Doc.Imports));
    for i := 0 to High(C.Doc.Imports) do
    begin
      C.Deps[i].Alias := C.Doc.Imports[i].Alias;
      DepPath := ResolveImport(C, C.Doc.Imports[i], DepRoot);
      C.Deps[i].Comp := Load(DepPath, DepRoot);
    end;
  except
    (* a broken component must not be served from the cache: the next file
       that imports it reports the same error again *)
    FCache.Delete(FCache.IndexOf(Abs));
    FNames.Delete(FNames.IndexOf(C.FuncName));
    C.Free;
    raise;
  end;
  Result := C;
end;

function TCompiler.CompileModule(C: TComponent): string;
var
  Order: array of TComponent;
  Visited: TStringList;
  Css, Js, Srcs: TStringList;
  Out: TBuf;
  Counter: Integer;
  i: Integer;
  G: TFuncGen;

  procedure Visit(X: TComponent);
  var
    k: Integer;
  begin
    if Visited.IndexOf(X.Path) >= 0 then
      Exit;
    Visited.Add(X.Path);
    (* assets in Jx's order: the component's own first, then each import's,
       depth first, without repeats *)
    for k := 0 to High(X.Doc.Css) do
      if Css.IndexOf(X.Doc.Css[k]) < 0 then
        Css.Add(X.Doc.Css[k]);
    for k := 0 to High(X.Doc.Js) do
      if Js.IndexOf(X.Doc.Js[k]) < 0 then
        Js.Add(X.Doc.Js[k]);
    for k := 0 to High(X.Deps) do
      Visit(X.Deps[k].Comp);
    SetLength(Order, Length(Order) + 1);
    Order[High(Order)] := X;
  end;

  function Tuple(L: TStringList): string;
  var
    k: Integer;
  begin
    Result := '(';
    for k := 0 to L.Count - 1 do
      Result := Result + PyStr(L[k]) + ', ';
    Result := Result + ')';
  end;

begin
  SetLength(Order, 0);
  Visited := TStringList.Create;
  Css := TStringList.Create;
  Js := TStringList.Create;
  Out := TBuf.Create;
  try
    Visit(C);
    Out.Add('# Generated by minijx from ' + ExtractFileName(C.Path) + '. Do not edit.'#10);
    Out.Add('from minijx.runtime import UNDEFINED, Attrs, Loop, concat, escape, getattr_, getitem, has_attr'#10);
    Out.Add('from minijx.filters import FILTERS as _FILTERS'#10);
    Out.Add('from minijx.tests import TESTS as _TESTS'#10);
    Out.Add(#10'_s = str'#10#10);
    (* bumped whenever the shape of these constants changes, so a catalog
       can tell a module generated by an older minijx *)
    Out.Add('MINIJX_FORMAT = ' + IntToStr(ModuleFormat) + #10);
    Out.Add('CSS = ' + Tuple(Css) + #10);
    Out.Add('JS = ' + Tuple(Js) + #10);
    (* every .jx copied into this module, relative to it, so a catalog can
       tell the module is stale when any of them changes *)
    Srcs := TStringList.Create;
    try
      for i := 0 to High(Order) do
        Srcs.Add(ExtractRelativePath(ExtractFilePath(C.Path), Order[i].Path));
      Out.Add('SOURCES = ' + Tuple(Srcs) + #10#10);
    finally
      Srcs.Free;
    end;
    Counter := 0;
    for i := 0 to High(Order) do
    begin
      G := TFuncGen.Create(Order[i], @Counter);
      try
        Out.Add(#10 + G.Generate + #10);
      finally
        G.Free;
      end;
    end;
    Out.Add(#10'render = ' + C.FuncName + #10);
    Result := Out.Join;
  finally
    Out.Free;
    Visited.Free;
    Css.Free;
    Js.Free;
  end;
end;

end.
