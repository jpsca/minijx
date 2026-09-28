(* minijx: from .jx files to Python modules.

  A TCompiler loads .jx files, resolves their `{# import #}` declarations
  against the root folders, and emits one Python module per file. Every
  component the file depends on (transitively) is copied into that module as
  a private function, so the module only imports the minijx runtime. *)
unit mjcompiler;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, mjerrors, mjutil, mjparser, mjcomponent, mjdefs, mjgen;

type
  TCompiler = class
  private
    FRoots: TStringArray; (* absolute, with a trailing separator *)
    FCache: TStringList;  (* absolute path -> TComponent *)
    FNames: TStringList;  (* function names already given out *)
    function ResolveImport(C: TComponent; const D: TImportDecl; out RootIdx: Integer): string;
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
     src/minijx/catalog.py. 3: CSS/JS are plain URLs (2 had pairs).
     4: `|default` receives UNDEFINED, not None, for a missing value.
     5: filters and tests are looked up in dicts (`_f["name"]`), which the
        catalog can replace with its own. *)
  ModuleFormat = 5;
  (* Taken from $MINIJX_VERSION when compiling, which the Makefile and the
     wheel build set from `version` in pyproject.toml, so the
     version lives in one place. Empty if fpc is run without it. *)
  MinijxVersion = {$I %MINIJX_VERSION%};

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

(* `_c_<rel path>`, unique across the run: `a/b.jx` and `a_b.jx` would both
   give `_c_a_b`, so the second one gets a numeric suffix. *)
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

function ReadFile(const Path: string): string;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

function TCompiler.Load(const Path: string; RootIdx: Integer): TComponent;
var
  Idx, i, DepRoot: Integer;
  Src, Abs, DepPath: string;
  C: TComponent;
begin
  Abs := ExpandFileName(Path);
  Idx := FCache.IndexOf(Abs);
  if Idx >= 0 then
    Exit(TComponent(FCache.Objects[Idx]));

  Src := ReadFile(Abs);
  C := TComponent.Create;
  C.Path := Abs;
  C.RootIdx := RootIdx;
  C.FuncName := MangledName(Abs, RootIdx);
  C.UsesAttrs := Pos('attrs', Src) > 0;
  (* registered before its imports are resolved, so cycles (a component
     importing itself, too) end *)
  FCache.AddObject(Abs, C);
  try
    C.Doc := ParseDocument(Abs, Src);
    C.Args := ParseDefArgs(C.Doc);
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
  Visited, Css, Js, Srcs: TStringList;
  Out: TBuf;
  Counter, i: Integer;
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
  Srcs := TStringList.Create;
  Out := TBuf.Create;
  try
    Visit(C);
    (* every .jx copied into this module, relative to it, so a catalog can
       tell the module is stale when any of them changes *)
    for i := 0 to High(Order) do
      Srcs.Add(ExtractRelativePath(ExtractFilePath(C.Path), Order[i].Path));

    Out.Add('# Generated by minijx from ' + ExtractFileName(C.Path) + '. Do not edit.'#10);
    Out.Add('from minijx.runtime import UNDEFINED, Attrs, Loop, concat, escape, getattr_, getitem, has_attr'#10);
    Out.Add('from minijx.filters import FILTERS as _FILTERS'#10);
    Out.Add('from minijx.tests import TESTS as _TESTS'#10);
    Out.Add(#10'_s = str'#10#10);
    (* bumped whenever the layout of the module changes, so a catalog can
       tell a module generated by another minijx *)
    Out.Add('MINIJX_FORMAT = ' + IntToStr(ModuleFormat) + #10);
    Out.Add('CSS = ' + Tuple(Css) + #10);
    Out.Add('JS = ' + Tuple(Js) + #10);
    Out.Add('SOURCES = ' + Tuple(Srcs) + #10#10);
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
    Srcs.Free;
    Visited.Free;
    Css.Free;
    Js.Free;
  end;
end;

end.
