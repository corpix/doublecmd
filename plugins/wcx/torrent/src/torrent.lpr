{
  Double Commander
  -------------------------------------------------------------------------
  BitTorrent archiver plugin

  Copyright (C) 2017 Alexander Koblov (alexx2000@mail.ru)

  This library is free software; you can redistribute it and/or
  modify it under the terms of the GNU Lesser General Public
  License as published by the Free Software Foundation; either
  version 2.1 of the License, or (at your option) any later version.

  This library is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
  Lesser General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License
  along with this program. If not, see <https://www.gnu.org/licenses/>.
}

library torrent;

{$mode delphi}
{$include calling.inc}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  FPCAdds,
  Classes, SysUtils, Process, TorrentFile, WcxPlugin, DCDateTimeUtils,
  DCClassesUtf8, DCConvertEncoding, DCOSUtils;

type
  PTorrentHandle = ^TTorrentHandle;
  TTorrentHandle = record
   Index: Integer;
   Torrent: TTorrentFile;
   ArcName: String;
   DownloadDir: String;
  end;

const
  Aria2Executable = 'aria2c';
  ProgressChunk = 1000000000;

var
  gProcessDataProc: TProcessDataProc = nil;
  gProcessDataProcW: TProcessDataProcW = nil;

function ReportProgress(const DisplayName: UnicodeString; Delta: Int64): LongInt;
var
  AName: WideString;
  Step: LongInt;
begin
  Result:= 1;
  AName:= DisplayName;
  while Delta > 0 do
  begin
    if Delta > ProgressChunk then Step:= ProgressChunk else Step:= LongInt(Delta);
    if Assigned(gProcessDataProcW) then
      Result:= gProcessDataProcW(PWideChar(AName), Step)
    else if Assigned(gProcessDataProc) then
      Result:= gProcessDataProc(PAnsiChar(CeUtf16ToUtf8(DisplayName)), Step);
    Dec(Delta, Step);
    if Result = 0 then Exit;
  end;
end;

function ParseLastPercent(const S: String): Integer;
var
  I, J: Integer;
  Num: String;
begin
  Result:= -1;
  for I:= System.Length(S) downto 1 do
  begin
    if S[I] = '%' then
    begin
      J:= I - 1;
      Num:= '';
      while (J >= 1) and (S[J] in ['0'..'9']) do
      begin
        Num:= S[J] + Num;
        Dec(J);
      end;
      if (Num <> '') and (J >= 1) and (S[J] = '(') then
        Exit(StrToIntDef(Num, -1));
    end;
  end;
end;

function CreateDownloadDir: String;
var
  ABase: String;
begin
  ABase:= IncludeTrailingPathDelimiter(GetTempDir) + 'dc_torrent_';
  repeat
    Result:= ABase + IntToStr(Random(MaxInt));
  until (not mbFileExists(Result)) and mbCreateDir(Result);
end;

procedure DeleteTree(const ADir: String);
var
  SR: TSearchRec;
  AFull: String;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      AFull:= IncludeTrailingPathDelimiter(ADir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        DeleteTree(AFull)
      else
        mbDeleteFile(AFull);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  mbRemoveDir(ADir);
end;

function MoveResult(const ASource, ADest: String): Boolean;
var
  ASrc, ADst: TFileStreamEx;
  Buffer: array[0..65535] of Byte;
  Count: LongInt;
begin
  ForceDirectories(ExtractFilePath(ADest));
  if mbFileExists(ADest) then mbDeleteFile(ADest);
  if mbRenameFile(ASource, ADest) then Exit(True);
  Result:= False;
  try
    ASrc:= TFileStreamEx.Create(ASource, fmOpenRead or fmShareDenyNone);
    try
      ADst:= TFileStreamEx.Create(ADest, fmCreate);
      try
        repeat
          Count:= ASrc.Read(Buffer, SizeOf(Buffer));
          if Count > 0 then ADst.WriteBuffer(Buffer, Count);
        until Count = 0;
      finally
        ADst.Free;
      end;
    finally
      ASrc.Free;
    end;
    mbDeleteFile(ASource);
    Result:= True;
  except
    Result:= False;
  end;
end;

function DownloadFile(AHandle: PTorrentHandle; AFile: TTorrentSubFile;
                      AIndex: Integer; const ADest: String): Integer;
var
  AProcess: TProcess;
  ATail: String;
  ASource: String;
  Buffer: array[0..4095] of Byte;
  Count, Percent: LongInt;
  Reported, Current: Int64;
begin
  AProcess:= TProcess.Create(nil);
  try
    AProcess.Executable:= Aria2Executable;
    AProcess.Parameters.Add('--dir=' + AHandle.DownloadDir);
    AProcess.Parameters.Add('--select-file=' + IntToStr(AIndex));
    AProcess.Parameters.Add('--seed-time=0');
    AProcess.Parameters.Add('--file-allocation=none');
    AProcess.Parameters.Add('--allow-overwrite=true');
    AProcess.Parameters.Add('--auto-file-renaming=false');
    AProcess.Parameters.Add('--summary-interval=1');
    AProcess.Parameters.Add('--enable-color=false');
    AProcess.Parameters.Add(AHandle.ArcName);
    AProcess.Options:= [poUsePipes, poStderrToOutPut];

    try
      AProcess.Execute;
    except
      Exit(E_EWRITE);
    end;

    Result:= E_SUCCESS;
    Reported:= 0;
    while True do
    begin
      if AProcess.Output.NumBytesAvailable > 0 then
      begin
        Count:= AProcess.Output.Read(Buffer, SizeOf(Buffer));
        if Count > 0 then
        begin
          SetString(ATail, PAnsiChar(@Buffer[0]), Count);
          Percent:= ParseLastPercent(ATail);
          if Percent >= 0 then
          begin
            Current:= AFile.Length * Percent div 100;
            if Current > Reported then
            begin
              if ReportProgress(CeUtf8ToUtf16(ADest), Current - Reported) = 0 then
              begin
                AProcess.Terminate(0);
                Exit(E_EABORTED);
              end;
              Reported:= Current;
            end;
          end;
        end;
      end
      else if not AProcess.Running then
        Break
      else
        Sleep(100);
    end;

    if AProcess.ExitStatus <> 0 then Exit(E_BAD_ARCHIVE);
  finally
    AProcess.Free;
  end;

  if AHandle.Torrent.Multifile then
    ASource:= IncludeTrailingPathDelimiter(AHandle.DownloadDir) +
              IncludeTrailingPathDelimiter(AHandle.Torrent.Name) +
              AFile.Path + AFile.Name
  else
    ASource:= IncludeTrailingPathDelimiter(AHandle.DownloadDir) +
              AFile.Path + AFile.Name;

  if not MoveResult(ASource, ADest) then Exit(E_EWRITE);

  if AFile.Length > Reported then
    ReportProgress(CeUtf8ToUtf16(ADest), AFile.Length - Reported);
end;

function OpenArchive(var ArchiveData : tOpenArchiveData) : TArcHandle; dcpcall;
begin
  Result := 0;
  ArchiveData.OpenResult := E_NOT_SUPPORTED;
end;

function OpenArchiveW(var ArchiveData : tOpenArchiveDataW) : TArcHandle; dcpcall;
var
  AFileName: String;
  AStream: TFileStreamEx;
  AHandle: PTorrentHandle = nil;
begin
  Result:= 0;
  try
    AFileName := CeUtf16ToUtf8(UnicodeString(ArchiveData.ArcName));
    AStream:= TFileStreamEx.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      New(AHandle);
      AHandle.Index:= 0;
      AHandle.ArcName:= AFileName;
      AHandle.DownloadDir:= EmptyStr;
      AHandle.Torrent:= TTorrentFile.Create;
      if not AHandle.Torrent.Load(AStream) then
        raise Exception.Create(EmptyStr);
      if ArchiveData.OpenMode = PK_OM_EXTRACT then
        AHandle.DownloadDir:= CreateDownloadDir;
      Result:= TArcHandle(AHandle);
    finally
      AStream.Free;
    end;
  except
    ArchiveData.OpenResult:= E_EOPEN;
    if Assigned(AHandle) then
    begin
      AHandle.Torrent.Free;
      Dispose(AHandle);
    end;
  end;
end;

function ReadHeader(hArcData : TArcHandle; var HeaderData: THeaderData) : Integer; dcpcall;
begin
  Result := E_NOT_SUPPORTED;
end;

function ReadHeaderExW(hArcData : TArcHandle; var HeaderData: THeaderDataExW) : Integer; dcpcall;
var
  AFile: TTorrentSubFile;
  AHandle: PTorrentHandle absolute hArcData;
begin
  if AHandle.Index >= AHandle.Torrent.Files.Count then Exit(E_END_ARCHIVE);

  AFile:= TTorrentSubFile(AHandle.Torrent.Files[AHandle.Index]);
  HeaderData.FileTime:= UnixFileTimeToWcxTime(AHandle.Torrent.CreationTime);
  HeaderData.FileName:= CeUtf8ToUtf16(AFile.Path + AFile.Name);
  HeaderData.UnpSize:= Int64Rec(AFile.Length).Lo;
  HeaderData.UnpSizeHigh:= Int64Rec(AFile.Length).Hi;
  HeaderData.PackSize:= HeaderData.UnpSize;
  HeaderData.PackSizeHigh:= HeaderData.UnpSizeHigh;
  Result:= E_SUCCESS;
end;

function ProcessFile(hArcData : TArcHandle; Operation : Integer; DestPath, DestName : PChar) : Integer; dcpcall;
begin
  Result := E_NOT_SUPPORTED;
end;

function ProcessFileW(hArcData : TArcHandle; Operation : Integer; DestPath, DestName : PWideChar) : Integer; dcpcall;
var
  AFile: TTorrentSubFile;
  ADest: String;
  AHandle: PTorrentHandle absolute hArcData;
begin
  Result:= E_SUCCESS;
  if Operation = PK_EXTRACT then
  begin
    AFile:= TTorrentSubFile(AHandle.Torrent.Files[AHandle.Index]);
    ADest:= CeUtf16ToUtf8(UnicodeString(DestPath)) + CeUtf16ToUtf8(UnicodeString(DestName));
    Result:= DownloadFile(AHandle, AFile, AHandle.Index + 1, ADest);
  end;
  Inc(AHandle.Index);
end;

function CloseArchive (hArcData : TArcHandle) : Integer; dcpcall;
var
  AHandle: PTorrentHandle absolute hArcData;
begin
  if hArcData <> wcxInvalidHandle then
  begin
    if (System.Length(AHandle.DownloadDir) > 0) and mbFileExists(AHandle.DownloadDir) then
      DeleteTree(AHandle.DownloadDir);
    AHandle.Torrent.Free;
    Dispose(AHandle);
  end;
  Result:= E_SUCCESS;
end;

procedure SetChangeVolProc (hArcData : TArcHandle; pChangeVolProc : TChangeVolProc); dcpcall;
begin

end;

procedure SetProcessDataProc (hArcData : TArcHandle; pProcessDataProc : TProcessDataProc); dcpcall;
begin
  gProcessDataProc:= pProcessDataProc;
end;

procedure SetProcessDataProcW (hArcData : TArcHandle; pProcessDataProc : TProcessDataProcW); dcpcall;
begin
  gProcessDataProcW:= pProcessDataProc;
end;

function GetPackerCaps : Integer;dcpcall;
begin
  Result := PK_CAPS_MULTIPLE;
end;

exports
  OpenArchive,
  OpenArchiveW,
  ReadHeader,
  ReadHeaderExW,
  ProcessFile,
  ProcessFileW,
  CloseArchive,
  SetChangeVolProc,
  SetProcessDataProc,
  SetProcessDataProcW,
  GetPackerCaps;

begin
  Randomize;
end.
