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
  Base64, Classes, SysUtils, Process, fphttpclient, fpjson, jsonparser,
  TorrentFile, WcxPlugin, DCDateTimeUtils, DCClassesUtf8, DCConvertEncoding,
  DCOSUtils;

type
  PWcxBatchProcessItemWArray = ^TWcxBatchProcessItemWArray;
  TWcxBatchProcessItemWArray = array[0..(MaxInt div SizeOf(TWcxBatchProcessItemW)) - 1] of TWcxBatchProcessItemW;

  TTorrentBatchItem = record
    ArchiveIndex: Integer;
    SourceName: String;
    DestName: String;
    Length: Int64;
  end;

  PTorrentHandle = ^TTorrentHandle;
  TTorrentHandle = record
   Index: Integer;
   Torrent: TTorrentFile;
   ArcName: String;
   DownloadDir: String;
   RpcUrl: String;
   RpcSecret: String;
   Gid: String;
   Process: TProcess;
   StopRequested: Boolean;
   PauseRequested: Boolean;
   ProcessDataProc: TProcessDataProc;
   ProcessDataProcW: TProcessDataProcW;
  end;

const
  Aria2Executable = 'aria2c';

function CallProcessData(AHandle: PTorrentHandle; const DisplayName: UnicodeString;
                         Size: LongInt; UpdateName: Boolean = True): LongInt;
var
  AName: WideString;
  ANamePtr: PWideChar;
  AAnsiName: AnsiString;
  AAnsiNamePtr: PAnsiChar;
begin
  Result:= 1;
  AName:= DisplayName;
  if UpdateName then
    ANamePtr:= PWideChar(AName)
  else
    ANamePtr:= nil;
  if Assigned(AHandle.ProcessDataProcW) then
    Result:= AHandle.ProcessDataProcW(ANamePtr, Size)
  else if Assigned(AHandle.ProcessDataProc) then
  begin
    if UpdateName then
    begin
      AAnsiName:= CeUtf16ToUtf8(DisplayName);
      AAnsiNamePtr:= PAnsiChar(AAnsiName);
    end
    else
      AAnsiNamePtr:= nil;
    Result:= AHandle.ProcessDataProc(AAnsiNamePtr, Size);
  end;
end;

function CreateRpcSecret: String;
begin
  Result:= IntToHex(Random(MaxInt), 8) + IntToHex(Random(MaxInt), 8) +
           IntToHex(Random(MaxInt), 8) + IntToHex(Random(MaxInt), 8);
end;

function JsonRpcCall(AHandle: PTorrentHandle; const Method: String;
                     Params: TJSONArray; out Response: TJSONObject): Boolean;
var
  Request: TJSONObject = nil;
  Client: TFPHTTPClient = nil;
  Body: TRawByteStringStream = nil;
  Data: TJSONData = nil;
  ResponseText: RawByteString;
begin
  Result:= False;
  Response:= nil;
  try
    Request:= TJSONObject.Create;
    Request.Add('jsonrpc', '2.0');
    Request.Add('id', 'dc');
    Request.Add('method', Method);
    if Assigned(Params) then
    begin
      Request.Add('params', Params);
      Params:= nil;
    end;

    Body:= TRawByteStringStream.Create(Request.AsJSON);
    Client:= TFPHTTPClient.Create(nil);
    Client.AddHeader('Content-Type', 'application/json');
    Client.RequestBody:= Body;
    ResponseText:= Client.Post(AHandle.RpcUrl);

    Data:= GetJSON(ResponseText);
    if Data is TJSONObject then
    begin
      Response:= TJSONObject(Data);
      Data:= nil;
      Result:= not Assigned(Response.Find('error'));
    end;
  except
    FreeAndNil(Response);
  end;

  if Assigned(Params) then Params.Free;
  Body.Free;
  Client.Free;
  Request.Free;
  Data.Free;
end;

function TokenParams(AHandle: PTorrentHandle): TJSONArray;
begin
  Result:= TJSONArray.Create;
  Result.Add('token:' + AHandle.RpcSecret);
end;

function GidParams(AHandle: PTorrentHandle): TJSONArray;
begin
  Result:= TokenParams(AHandle);
  Result.Add(AHandle.Gid);
end;

function JsonRpcSimple(AHandle: PTorrentHandle; const Method: String;
                       Params: TJSONArray = nil): Boolean;
var
  Response: TJSONObject = nil;
begin
  Result:= JsonRpcCall(AHandle, Method, Params, Response);
  Response.Free;
end;

function JsonRpcStringResult(AHandle: PTorrentHandle; const Method: String;
                             Params: TJSONArray; out Value: String): Boolean;
var
  Response: TJSONObject = nil;
begin
  Result:= JsonRpcCall(AHandle, Method, Params, Response);
  if Result then
    Value:= Response.Get('result', EmptyStr);
  Response.Free;
end;

function JsonRpcObjectResult(AHandle: PTorrentHandle; const Method: String;
                             Params: TJSONArray; out Value: TJSONObject): Boolean;
var
  Response: TJSONObject = nil;
  Data: TJSONData;
begin
  Result:= False;
  Value:= nil;
  if JsonRpcCall(AHandle, Method, Params, Response) then
  begin
    Data:= Response.Find('result');
    if Data is TJSONObject then
    begin
      Value:= TJSONObject(Data.Clone);
      Result:= True;
    end;
  end;
  Response.Free;
end;

function JsonRpcArrayResult(AHandle: PTorrentHandle; const Method: String;
                            Params: TJSONArray; out Value: TJSONArray): Boolean;
var
  Response: TJSONObject = nil;
  Data: TJSONData;
begin
  Result:= False;
  Value:= nil;
  if JsonRpcCall(AHandle, Method, Params, Response) then
  begin
    Data:= Response.Find('result');
    if Data is TJSONArray then
    begin
      Value:= TJSONArray(Data.Clone);
      Result:= True;
    end;
  end;
  Response.Free;
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

function ReadFileBase64(const AFileName: String): String;
var
  Stream: TFileStreamEx;
  Buffer: RawByteString;
begin
  Stream:= TFileStreamEx.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Buffer, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Buffer[1], Stream.Size);
    Result:= EncodeStringBase64(Buffer);
  finally
    Stream.Free;
  end;
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

function TorrentDownloadPath(AHandle: PTorrentHandle; AFile: TTorrentSubFile): String;
begin
  if AHandle.Torrent.Multifile then
    Result:= IncludeTrailingPathDelimiter(AHandle.DownloadDir) +
             IncludeTrailingPathDelimiter(AHandle.Torrent.Name) +
             AFile.Path + AFile.Name
  else
    Result:= IncludeTrailingPathDelimiter(AHandle.DownloadDir) +
             AFile.Path + AFile.Name;
end;

function ReportTotalPercent(AHandle: PTorrentHandle; const DisplayName: String;
                            Percent: Integer): LongInt;
begin
  if Percent < 1 then Percent:= 1;
  if Percent > 100 then Percent:= 100;
  Result:= CallProcessData(AHandle, CeUtf8ToUtf16(DisplayName), -Percent, False);
end;

function ReportCurrentPercent(AHandle: PTorrentHandle; const DisplayName: String;
                              Percent: Integer): LongInt;
begin
  if Percent < 0 then Percent:= 0;
  if Percent > 100 then Percent:= 100;
  Result:= CallProcessData(AHandle, CeUtf8ToUtf16(DisplayName), -1000 - Percent);
end;

function ReportDoneFiles(AHandle: PTorrentHandle; Count: Integer): LongInt;
begin
  if Count < 0 then Count:= 0;
  Result:= CallProcessData(AHandle, UnicodeString(''), -2000 - Count, False);
end;

function StartAria2(AHandle: PTorrentHandle): Boolean;
var
  I, J, Port: Integer;
  Response: TJSONObject = nil;
begin
  Result:= False;
  AHandle.RpcSecret:= CreateRpcSecret;
  for I:= 1 to 10 do
  begin
    Port:= 1024 + Random(64000);
    AHandle.RpcUrl:= 'http://127.0.0.1:' + IntToStr(Port) + '/jsonrpc';
    AHandle.Process:= TProcess.Create(nil);
    AHandle.Process.Executable:= Aria2Executable;
    AHandle.Process.Parameters.Add('--enable-rpc=true');
    AHandle.Process.Parameters.Add('--rpc-listen-all=false');
    AHandle.Process.Parameters.Add('--rpc-listen-port=' + IntToStr(Port));
    AHandle.Process.Parameters.Add('--rpc-secret=' + AHandle.RpcSecret);
    AHandle.Process.Parameters.Add('--dir=' + AHandle.DownloadDir);
    AHandle.Process.Parameters.Add('--seed-time=0');
    AHandle.Process.Parameters.Add('--file-allocation=none');
    AHandle.Process.Parameters.Add('--allow-overwrite=true');
    AHandle.Process.Parameters.Add('--auto-file-renaming=false');
    AHandle.Process.Parameters.Add('--summary-interval=0');
    AHandle.Process.Parameters.Add('--show-console-readout=false');
    AHandle.Process.Parameters.Add('--console-log-level=warn');
    AHandle.Process.Parameters.Add('--enable-color=false');
    AHandle.Process.Parameters.Add('--rpc-save-upload-metadata=false');
    AHandle.Process.Options:= [poNoConsole];
    try
      AHandle.Process.Execute;
    except
      FreeAndNil(AHandle.Process);
      Exit(False);
    end;

    for J:= 1 to 20 do
    begin
      Sleep(100);
      if JsonRpcCall(AHandle, 'aria2.getVersion', TokenParams(AHandle), Response) then
      begin
        Response.Free;
        Exit(True);
      end;
      Response.Free;
      Response:= nil;
      if not AHandle.Process.Running then Break;
    end;
    AHandle.Process.Terminate(0);
    FreeAndNil(AHandle.Process);
  end;
end;

procedure StopAria2(AHandle: PTorrentHandle);
begin
  if AHandle.RpcUrl <> EmptyStr then
  begin
    if AHandle.Gid <> EmptyStr then
      JsonRpcSimple(AHandle, 'aria2.forceRemove', GidParams(AHandle));
    JsonRpcSimple(AHandle, 'aria2.forceShutdown', TokenParams(AHandle));
  end;
  if Assigned(AHandle.Process) then
  begin
    if AHandle.Process.Running then
      AHandle.Process.Terminate(0);
    FreeAndNil(AHandle.Process);
  end;
  AHandle.Gid:= EmptyStr;
end;

function AddTorrent(AHandle: PTorrentHandle; const SelectFiles: String): Boolean;
var
  Params: TJSONArray;
  Options: TJSONObject;
  EmptyUris: TJSONArray;
begin
  Params:= TokenParams(AHandle);
  Params.Add(ReadFileBase64(AHandle.ArcName));
  EmptyUris:= TJSONArray.Create;
  Params.Add(EmptyUris);
  Options:= TJSONObject.Create;
  Options.Add('dir', AHandle.DownloadDir);
  Options.Add('select-file', SelectFiles);
  Options.Add('seed-time', '0');
  Options.Add('file-allocation', 'none');
  Options.Add('allow-overwrite', 'true');
  Options.Add('auto-file-renaming', 'false');
  Options.Add('bt-remove-unselected-file', 'false');
  Params.Add(Options);
  Result:= JsonRpcStringResult(AHandle, 'aria2.addTorrent', Params, AHandle.Gid);
end;

function SelectedItemIndexByAriaIndex(const Items: array of TTorrentBatchItem;
                                      AriaIndex: Integer): Integer;
var
  I: Integer;
begin
  Result:= -1;
  for I:= Low(Items) to High(Items) do
  begin
    if Items[I].ArchiveIndex + 1 = AriaIndex then Exit(I);
  end;
end;

function PollTorrent(AHandle: PTorrentHandle; const Items: array of TTorrentBatchItem;
                     TotalBytes: Int64): Integer;
var
  Params: TJSONArray;
  Keys: TJSONArray;
  Status: TJSONObject = nil;
  Files: TJSONArray = nil;
  FileObj: TJSONObject;
  State: String;
  Completed, FileCompleted, FileLength: Int64;
  I, AriaIndex, ItemIndex, CompletedFiles: Integer;
  TotalPercent, CurrentPercent, BestPercent, BestItemIndex: Integer;
begin
  Result:= E_SUCCESS;
  while True do
  begin
    if AHandle.StopRequested then Exit(E_EABORTED);

    Params:= TokenParams(AHandle);
    Params.Add(AHandle.Gid);
    Keys:= TJSONArray.Create;
    Keys.Add('status');
    Keys.Add('completedLength');
    Keys.Add('errorCode');
    Keys.Add('errorMessage');
    Params.Add(Keys);
    if not JsonRpcObjectResult(AHandle, 'aria2.tellStatus', Params, Status) then
    begin
      if AHandle.StopRequested then
        Exit(E_EABORTED)
      else
        Exit(E_BAD_ARCHIVE);
    end;
    try
      State:= Status.Get('status', EmptyStr);
      Completed:= StrToInt64Def(Status.Get('completedLength', '0'), 0);
      if TotalBytes > 0 then
      begin
        TotalPercent:= Completed * 100 div TotalBytes;
        if TotalPercent > 0 then
        begin
          if ReportTotalPercent(AHandle, Items[0].SourceName, TotalPercent) = 0 then
          begin
            AHandle.StopRequested:= True;
            StopAria2(AHandle);
            Exit(E_EABORTED);
          end;
        end;
      end;

      Params:= TokenParams(AHandle);
      Params.Add(AHandle.Gid);
      if JsonRpcArrayResult(AHandle, 'aria2.getFiles', Params, Files) then
      begin
        try
          BestPercent:= MaxInt;
          BestItemIndex:= -1;
          CompletedFiles:= 0;
          for I:= 0 to Files.Count - 1 do
          begin
            if not (Files.Items[I] is TJSONObject) then Continue;
            FileObj:= TJSONObject(Files.Items[I]);
            AriaIndex:= StrToIntDef(FileObj.Get('index', '0'), 0);
            ItemIndex:= SelectedItemIndexByAriaIndex(Items, AriaIndex);
            if ItemIndex < 0 then Continue;

            FileLength:= StrToInt64Def(FileObj.Get('length', '0'), Items[ItemIndex].Length);
            FileCompleted:= StrToInt64Def(FileObj.Get('completedLength', '0'), 0);
            if FileLength <= 0 then
              CurrentPercent:= 100
            else
              CurrentPercent:= FileCompleted * 100 div FileLength;

            if CurrentPercent >= 100 then Inc(CompletedFiles);

            if (CurrentPercent < 100) and (CurrentPercent < BestPercent) then
            begin
              BestPercent:= CurrentPercent;
              BestItemIndex:= ItemIndex;
            end;
          end;

          if BestItemIndex >= 0 then
          begin
            if ReportCurrentPercent(AHandle, Items[BestItemIndex].SourceName, BestPercent) = 0 then
            begin
              AHandle.StopRequested:= True;
              StopAria2(AHandle);
              Exit(E_EABORTED);
            end;
          end
          else if Length(Items) > 0 then
          begin
            if ReportCurrentPercent(AHandle, Items[High(Items)].SourceName, 100) = 0 then
            begin
              AHandle.StopRequested:= True;
              StopAria2(AHandle);
              Exit(E_EABORTED);
            end;
          end;

          if ReportDoneFiles(AHandle, CompletedFiles) = 0 then
          begin
            AHandle.StopRequested:= True;
            StopAria2(AHandle);
            Exit(E_EABORTED);
          end;
        finally
          Files.Free;
          Files:= nil;
        end;
      end;

      if State = 'complete' then Break;
      if (State = 'error') or (State = 'removed') then Exit(E_BAD_ARCHIVE);
    finally
      Status.Free;
    end;
    Sleep(500);
  end;

  if TotalBytes > 0 then
    if ReportTotalPercent(AHandle, Items[0].SourceName, 100) = 0 then
      Result:= E_EABORTED;
  if Result = E_SUCCESS then
    if ReportDoneFiles(AHandle, Length(Items)) = 0 then
      Result:= E_EABORTED;
end;

function DownloadFiles(AHandle: PTorrentHandle; const Items: array of TTorrentBatchItem): Integer;
var
  I: Integer;
  AFile: TTorrentSubFile;
  SelectFiles, SourcePath: String;
  TotalBytes: Int64;
begin
  Result:= E_SUCCESS;
  if Length(Items) = 0 then Exit;

  SelectFiles:= EmptyStr;
  TotalBytes:= 0;
  for I:= Low(Items) to High(Items) do
  begin
    if SelectFiles <> EmptyStr then SelectFiles:= SelectFiles + ',';
    SelectFiles:= SelectFiles + IntToStr(Items[I].ArchiveIndex + 1);
    Inc(TotalBytes, Items[I].Length);
  end;

  if not StartAria2(AHandle) then Exit(E_EWRITE);
  if not AddTorrent(AHandle, SelectFiles) then
  begin
    StopAria2(AHandle);
    Exit(E_BAD_ARCHIVE);
  end;

  if AHandle.PauseRequested then
    JsonRpcSimple(AHandle, 'aria2.forcePause', GidParams(AHandle));

  Result:= PollTorrent(AHandle, Items, TotalBytes);
  if Result <> E_SUCCESS then Exit;

  for I:= Low(Items) to High(Items) do
  begin
    AFile:= TTorrentSubFile(AHandle.Torrent.Files[Items[I].ArchiveIndex]);
    SourcePath:= TorrentDownloadPath(AHandle, AFile);
    if not MoveResult(SourcePath, Items[I].DestName) then Exit(E_EWRITE);
  end;
end;

function DownloadFile(AHandle: PTorrentHandle; AFile: TTorrentSubFile;
                      AIndex: Integer; const ADest: String): Integer;
var
  Items: array[0..0] of TTorrentBatchItem;
begin
  Items[0].ArchiveIndex:= AIndex - 1;
  Items[0].SourceName:= AFile.Path + AFile.Name;
  Items[0].DestName:= ADest;
  Items[0].Length:= AFile.Length;
  Result:= DownloadFiles(AHandle, Items);
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
      AHandle.RpcUrl:= EmptyStr;
      AHandle.RpcSecret:= EmptyStr;
      AHandle.Gid:= EmptyStr;
      AHandle.Process:= nil;
      AHandle.StopRequested:= False;
      AHandle.PauseRequested:= False;
      AHandle.ProcessDataProc:= nil;
      AHandle.ProcessDataProcW:= nil;
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

function ProcessFilesW(hArcData: TArcHandle; Items: PWcxBatchProcessItemW; Count: Integer): Integer; dcpcall;
var
  I: Integer;
  AFile: TTorrentSubFile;
  AItems: PWcxBatchProcessItemWArray absolute Items;
  AHandle: PTorrentHandle absolute hArcData;
  BatchItems: array of TTorrentBatchItem;
begin
  Result:= E_SUCCESS;
  if (Items = nil) or (Count <= 0) then Exit;

  SetLength(BatchItems, Count);
  for I:= 0 to Count - 1 do
  begin
    if (AItems^[I].ArchiveIndex < 0) or
       (AItems^[I].ArchiveIndex >= AHandle.Torrent.Files.Count) then
      Exit(E_BAD_ARCHIVE);

    AFile:= TTorrentSubFile(AHandle.Torrent.Files[AItems^[I].ArchiveIndex]);
    BatchItems[I].ArchiveIndex:= AItems^[I].ArchiveIndex;
    BatchItems[I].SourceName:= CeUtf16ToUtf8(UnicodeString(AItems^[I].SourceName));
    BatchItems[I].DestName:= CeUtf16ToUtf8(UnicodeString(AItems^[I].DestName));
    BatchItems[I].Length:= AFile.Length;
  end;

  Result:= DownloadFiles(AHandle, BatchItems);
end;

function CloseArchive (hArcData : TArcHandle) : Integer; dcpcall;
var
  AHandle: PTorrentHandle absolute hArcData;
begin
  if hArcData <> wcxInvalidHandle then
  begin
    StopAria2(AHandle);
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
var
  AHandle: PTorrentHandle absolute hArcData;
begin
  if hArcData <> wcxInvalidHandle then
    AHandle.ProcessDataProc:= pProcessDataProc;
end;

procedure SetProcessDataProcW (hArcData : TArcHandle; pProcessDataProc : TProcessDataProcW); dcpcall;
var
  AHandle: PTorrentHandle absolute hArcData;
begin
  if hArcData <> wcxInvalidHandle then
    AHandle.ProcessDataProcW:= pProcessDataProc;
end;

procedure PauseProcessFiles(hArcData: TArcHandle); dcpcall;
var
  AHandle: PTorrentHandle absolute hArcData;
begin
  if hArcData = wcxInvalidHandle then Exit;
  AHandle.PauseRequested:= True;
  if AHandle.Gid <> EmptyStr then
    JsonRpcSimple(AHandle, 'aria2.forcePause', GidParams(AHandle));
end;

procedure ResumeProcessFiles(hArcData: TArcHandle); dcpcall;
var
  AHandle: PTorrentHandle absolute hArcData;
begin
  if hArcData = wcxInvalidHandle then Exit;
  AHandle.PauseRequested:= False;
  if AHandle.Gid <> EmptyStr then
    JsonRpcSimple(AHandle, 'aria2.unpause', GidParams(AHandle));
end;

procedure StopProcessFiles(hArcData: TArcHandle); dcpcall;
var
  AHandle: PTorrentHandle absolute hArcData;
begin
  if hArcData = wcxInvalidHandle then Exit;
  AHandle.StopRequested:= True;
  StopAria2(AHandle);
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
  ProcessFilesW,
  CloseArchive,
  SetChangeVolProc,
  SetProcessDataProc,
  SetProcessDataProcW,
  PauseProcessFiles,
  ResumeProcessFiles,
  StopProcessFiles,
  GetPackerCaps;

begin
  Randomize;
end.
