(* minijx: small string helpers shared by the lexer, parser and code generator. *)
unit mjutil;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TStringArray = array of string;

  (* Append-only list of strings, joined at the end. *)
  TBuf = class
  private
    FItems: TStringArray;
    FCount: Integer;
  public
    procedure Add(const S: string);
    function Join(const Sep: string = ''): string;
    function Count: Integer;
    procedure Clear;
  end;

  (* Lines of Python at an indentation level. A block is generated into its
     own writer when the code around it depends on what the block needs, and
     then appended. *)
  TWriter = class
  private
    FBuf: TBuf;
  public
    Indent: Integer;
    constructor Create(AIndent: Integer = 0);
    destructor Destroy; override;
    procedure Line(const S: string);
    (* another writer's lines, already indented *)
    procedure Append(W: TWriter);
    function Count: Integer;
    function Text: string;
  end;

const
  WhitespaceChars = [' ', #9, #13, #10];
  NameStartChars = ['a'..'z', 'A'..'Z', '_'];
  NameChars = ['a'..'z', 'A'..'Z', '0'..'9', '_'];
  DigitChars = ['0'..'9'];
  TagNameStartChars = ['A'..'Z'];
  TagNameChars = ['a'..'z', 'A'..'Z', '0'..'9', '_', '.', ':', '$', '-'];
  TagNameEndChars = [' ', #9, #13, #10, '/', '>'];
  AttrNameStartChars = ['a'..'z', 'A'..'Z', ':', '@', '$', '_'];
  AttrNameChars = ['a'..'z', 'A'..'Z', '0'..'9', '@', ':', '$', '_', '-', '.'];

(* Python string literal (single quoted) for S. Bytes pass through as UTF-8. *)
function PyStr(const S: string): string;

(* True if S is a Python keyword and cannot be used as an identifier. *)
function IsPyKeyword(const S: string): Boolean;
(* True if S can be written as a Python name: `a_1`, not `1a`, `a-b`, `class`. *)
function IsPyIdentifier(const S: string): Boolean;

function IsBlank(const S: string): Boolean;
(* `\r\n` and `\r` to `\n`, as Jinja does with template source *)
function NormalizeNewlines(const S: string): string;
(* Strip the whitespace Python's str.strip() strips, ASCII part *)
function TrimLeftWS(const S: string): string;
function TrimRightWS(const S: string): string;
function StartsWith(const S, Prefix: string): Boolean;
function EndsWith(const S, Suffix: string): Boolean;
function ReplaceChar(const S: string; From, ToC: Char): string;
function StrRepeat(const S: string; N: Integer): string;
function Split(const S: string; Sep: Char): TStringArray;
function InList(const S: string; const Items: array of string): Boolean;

implementation

procedure TBuf.Add(const S: string);
begin
  if FCount = Length(FItems) then
    SetLength(FItems, 16 + FCount * 2);
  FItems[FCount] := S;
  Inc(FCount);
end;

function TBuf.Join(const Sep: string): string;
var
  i, Total, P: Integer;
begin
  Total := 0;
  for i := 0 to FCount - 1 do
    Inc(Total, Length(FItems[i]));
  if FCount > 1 then
    Inc(Total, Length(Sep) * (FCount - 1));
  SetLength(Result, Total);
  P := 1;
  for i := 0 to FCount - 1 do
  begin
    if (i > 0) and (Sep <> '') then
    begin
      Move(Sep[1], Result[P], Length(Sep));
      Inc(P, Length(Sep));
    end;
    if FItems[i] <> '' then
    begin
      Move(FItems[i][1], Result[P], Length(FItems[i]));
      Inc(P, Length(FItems[i]));
    end;
  end;
end;

function TBuf.Count: Integer;
begin
  Result := FCount;
end;

procedure TBuf.Clear;
begin
  FCount := 0;
end;

constructor TWriter.Create(AIndent: Integer);
begin
  Indent := AIndent;
  FBuf := TBuf.Create;
end;

destructor TWriter.Destroy;
begin
  FBuf.Free;
  inherited;
end;

procedure TWriter.Line(const S: string);
begin
  FBuf.Add(StrRepeat('    ', Indent) + S + #10);
end;

procedure TWriter.Append(W: TWriter);
begin
  if W.Count > 0 then
    FBuf.Add(W.Text);
end;

function TWriter.Count: Integer;
begin
  Result := FBuf.Count;
end;

function TWriter.Text: string;
begin
  Result := FBuf.Join;
end;

function PyStr(const S: string): string;
var
  i: Integer;
  B: TBuf;
begin
  B := TBuf.Create;
  try
    B.Add('''');
    for i := 1 to Length(S) do
      case S[i] of
        '\': B.Add('\\');
        '''': B.Add('\''');
        #10: B.Add('\n');
        #13: B.Add('\r');
        #9: B.Add('\t');
        #0..#8, #11, #12, #14..#31: B.Add('\x' + IntToHex(Ord(S[i]), 2));
      else
        B.Add(S[i]);
      end;
    B.Add('''');
    Result := B.Join;
  finally
    B.Free;
  end;
end;

function IsPyKeyword(const S: string): Boolean;
begin
  Result := InList(S, ['False', 'None', 'True', 'and', 'as', 'assert', 'async',
    'await', 'break', 'class', 'continue', 'def', 'del', 'elif', 'else',
    'except', 'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is',
    'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try',
    'while', 'with', 'yield']);
end;

function IsPyIdentifier(const S: string): Boolean;
var
  i: Integer;
begin
  if (S = '') or not (S[1] in NameStartChars) or IsPyKeyword(S) then
    Exit(False);
  for i := 2 to Length(S) do
    if not (S[i] in NameChars) then
      Exit(False);
  Result := True;
end;

function IsBlank(const S: string): Boolean;
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    if not (S[i] in WhitespaceChars) then
      Exit(False);
  Result := True;
end;

function NormalizeNewlines(const S: string): string;
var
  i, n: Integer;
begin
  if Pos(#13, S) = 0 then
    Exit(S);
  SetLength(Result, Length(S));
  n := 0;
  i := 1;
  while i <= Length(S) do
  begin
    Inc(n);
    if S[i] = #13 then
    begin
      Result[n] := #10;
      if (i < Length(S)) and (S[i + 1] = #10) then
        Inc(i);
    end
    else
      Result[n] := S[i];
    Inc(i);
  end;
  SetLength(Result, n);
end;

const
  StripChars = [' ', #9, #10, #11, #12, #13];

function TrimLeftWS(const S: string): string;
var
  i: Integer;
begin
  i := 1;
  while (i <= Length(S)) and (S[i] in StripChars) do
    Inc(i);
  Result := Copy(S, i, Length(S));
end;

function TrimRightWS(const S: string): string;
var
  i: Integer;
begin
  i := Length(S);
  while (i >= 1) and (S[i] in StripChars) do
    Dec(i);
  Result := Copy(S, 1, i);
end;

function StartsWith(const S, Prefix: string): Boolean;
begin
  Result := (Length(S) >= Length(Prefix)) and (Copy(S, 1, Length(Prefix)) = Prefix);
end;

function EndsWith(const S, Suffix: string): Boolean;
begin
  Result := (Length(S) >= Length(Suffix)) and
    (Copy(S, Length(S) - Length(Suffix) + 1, Length(Suffix)) = Suffix);
end;

function ReplaceChar(const S: string; From, ToC: Char): string;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] = From then
      Result[i] := ToC;
end;

function StrRepeat(const S: string; N: Integer): string;
var
  i: Integer;
begin
  Result := '';
  if N <= 0 then
    Exit;
  SetLength(Result, Length(S) * N);
  for i := 0 to N - 1 do
    Move(S[1], Result[i * Length(S) + 1], Length(S));
end;

function Split(const S: string; Sep: Char): TStringArray;
var
  i, Start, N: Integer;
begin
  SetLength(Result, 0);
  N := 0;
  Start := 1;
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] = Sep) then
    begin
      SetLength(Result, N + 1);
      Result[N] := Copy(S, Start, i - Start);
      Inc(N);
      Start := i + 1;
    end;
end;

function InList(const S: string; const Items: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Items) do
    if Items[i] = S then
      Exit(True);
  Result := False;
end;

end.
