(* minijx: compile .jx components to Python functions.

  Usage: minijx FOLDER [FOLDER ...]

  Every `name.jx` under the folders becomes `name.py` next to it; dots in the
  name become `_` (`sitemap.xml.jx` -> `sitemap_xml.py`). Absolute imports
  (`{# import "components/x.jx" as X #}`) are resolved against the folders in
  the order given. Exit code 1 if any file failed to compile, 2 for bad
  arguments. *)
program minijx;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, mjerrors, mjutil, mjcodegen;

procedure Usage(const Msg: string = '');
begin
  if Msg <> '' then
    WriteLn(StdErr, 'minijx: ', Msg);
  WriteLn(StdErr, 'usage: minijx FOLDER [FOLDER ...]');
  WriteLn(StdErr, '       minijx --version');
  WriteLn(StdErr, '  Compiles every .jx file under the folders to a sibling .py file.');
  Halt(2);
end;

procedure CollectJx(const Dir: string; Files: TStringList);
var
  SR: TSearchRec;
  Path: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      Path := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        CollectJx(Path, Files)
      else if EndsWith(SR.Name, '.jx') then
        Files.Add(Path);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

procedure WriteText(const Path, Text: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    if Text <> '' then
      F.WriteBuffer(Text[1], Length(Text));
  finally
    F.Free;
  end;
end;

var
  Roots: TStringArray;
  Files: TStringList;
  Outputs: TStringList;    (* output paths already claimed... *)
  OutputSrcs: TStringList; (* ...and the .jx file that claimed each *)
  Compiler: TCompiler;
  i, j, k, Failed, Written: Integer;
  Arg, OutPath, Code: string;
  Comp: TComponent;
begin
  if ParamCount < 1 then
    Usage;
  SetLength(Roots, ParamCount);
  for i := 1 to ParamCount do
  begin
    Arg := ParamStr(i);
    if (Arg = '-h') or (Arg = '--help') then
      Usage;
    if Arg = '--version' then
    begin
      (* the runtime reads the format to refuse a binary that generates
         modules it cannot load *)
      WriteLn('minijx ', MinijxVersion, ' (module format ', ModuleFormat, ')');
      Halt(0);
    end;
    if StartsWith(Arg, '-') then
      Usage('unknown option ' + Arg);
    if not DirectoryExists(Arg) then
    begin
      WriteLn(StdErr, 'minijx: not a folder: ', Arg);
      Halt(2);
    end;
    Roots[i - 1] := IncludeTrailingPathDelimiter(ExpandFileName(Arg));
  end;

  Failed := 0;
  Written := 0;
  Compiler := TCompiler.Create(Roots);
  Files := TStringList.Create;
  Outputs := TStringList.Create;
  OutputSrcs := TStringList.Create;
  try
    for i := 0 to High(Roots) do
    begin
      Files.Clear;
      CollectJx(Roots[i], Files);
      Files.Sort;
      for j := 0 to Files.Count - 1 do
      begin
        OutPath := OutputPath(Files[j]);
        try
          k := Outputs.IndexOf(OutPath);
          if k >= 0 then
            raise ECompileError.Create(Files[j], 1, 1, 'Output ' +
              ExtractFileName(OutPath) + ' would overwrite the one compiled from ' +
              OutputSrcs[k]);
          Outputs.Add(OutPath);
          OutputSrcs.Add(Files[j]);
          Comp := Compiler.Load(Files[j], i);
          Code := Compiler.CompileModule(Comp);
          WriteText(OutPath, Code);
          Inc(Written);
        except
          on E: ECompileError do
          begin
            WriteLn(StdErr, E.Format);
            Inc(Failed);
          end;
          on E: Exception do
          begin
            WriteLn(StdErr, Files[j], ': ', E.ClassName, ': ', E.Message);
            Inc(Failed);
          end;
        end;
      end;
    end;
  finally
    Files.Free;
    Outputs.Free;
    OutputSrcs.Free;
    Compiler.Free;
  end;
  WriteLn(StdErr, 'minijx: ', Written, ' file(s) written, ', Failed, ' failed');
  if Failed > 0 then
    Halt(1);
end.
