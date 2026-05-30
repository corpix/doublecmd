{
   Double Commander
   -------------------------------------------------------------------------
   Per-directory settings stored in the central configuration directory

   Copyright (C) 2026

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2 of the License, or
   (at your option) any later version.
}

unit uDirectorySettings;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DCXmlConfig, uFileSorting, uFileFunctions;

const
  DirectorySettingsConfig = 'directory_settings.xml';

type

  TDirectoryViewType = (dvtNone, dvtColumns, dvtBrief, dvtThumbnails);

  { TDirectorySettingsEntry }

  TDirectorySettingsEntry = class
  private
    FColumnSet: String;
    FSortings: TFileSortings;
    FViewType: TDirectoryViewType;
  public
    destructor Destroy; override;
    function HasSettings: Boolean;

    property ColumnSet: String read FColumnSet write FColumnSet;
    property Sortings: TFileSortings read FSortings write FSortings;
    property ViewType: TDirectoryViewType read FViewType write FViewType;
  end;

  { TDirectorySettings }

  TDirectorySettings = class
  private
    FEntries: TStringList;

    function FindEntry(const APath: String): TDirectorySettingsEntry;
    function FindOrCreateEntry(const APath: String): TDirectorySettingsEntry;
    function GetCount: Integer;
    function NormalizePath(const APath: String): String;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    procedure LoadFromFile(const AFileName: String);
    procedure SaveToFile(const AFileName: String);
    function TryGetSorting(const APath: String; out ASortings: TFileSortings): Boolean;
    function TryGetView(const APath: String; out AViewType: TDirectoryViewType;
                        out AColumnSet: String): Boolean;
    procedure SetSorting(const APath: String; const ASortings: TFileSortings);
    procedure SetView(const APath: String; AViewType: TDirectoryViewType;
                      const AColumnSet: String = '');

    property Count: Integer read GetCount;
  end;

var
  gDirectorySettings: TDirectorySettings;

implementation

uses
  DCOSUtils, DCStrUtils;

function DirectoryViewTypeToString(AViewType: TDirectoryViewType): String;
begin
  case AViewType of
    dvtColumns:
      Result := 'columns';
    dvtBrief:
      Result := 'brief';
    dvtThumbnails:
      Result := 'thumbnails';
  else
    Result := EmptyStr;
  end;
end;

function TryStringToDirectoryViewType(const AValue: String; out AViewType: TDirectoryViewType): Boolean;
begin
  Result := True;
  if AValue = 'columns' then
    AViewType := dvtColumns
  else if AValue = 'brief' then
    AViewType := dvtBrief
  else if AValue = 'thumbnails' then
    AViewType := dvtThumbnails
  else begin
    AViewType := dvtNone;
    Result := False;
  end;
end;

function LoadSortings(AConfig: TXmlConfig; ANode: TXmlNode): TFileSortings;
var
  SortingsNode, SortingSubNode, SortFunctionNode: TXmlNode;
  SortDirection: TSortDirection;
  SortFunctions: TFileFunctions;
  SortFunctionInt: Integer;
begin
  Result := nil;
  SortingsNode := AConfig.FindNode(ANode, 'Sortings');
  if not Assigned(SortingsNode) then Exit;

  SortingSubNode := SortingsNode.FirstChild;
  while Assigned(SortingSubNode) do
  begin
    if SortingSubNode.CompareName('Sorting') = 0 then
    begin
      if AConfig.TryGetValue(SortingSubNode, 'Direction', Integer(SortDirection)) then
      begin
        SortFunctions := nil;
        SortFunctionNode := SortingSubNode.FirstChild;
        while Assigned(SortFunctionNode) do
        begin
          if SortFunctionNode.CompareName('Function') = 0 then
          begin
            if TryStrToInt(AConfig.GetContent(SortFunctionNode), SortFunctionInt) then
              AddSortFunction(SortFunctions, TFileFunction(SortFunctionInt));
          end;
          SortFunctionNode := SortFunctionNode.NextSibling;
        end;
        AddSorting(Result, SortFunctions, SortDirection);
      end;
    end;
    SortingSubNode := SortingSubNode.NextSibling;
  end;
end;

procedure SaveSortings(AConfig: TXmlConfig; ANode: TXmlNode; const ASortings: TFileSortings);
var
  I, J: Integer;
  SortingsNode, SortingSubNode: TXmlNode;
begin
  if Length(ASortings) = 0 then Exit;

  SortingsNode := AConfig.FindNode(ANode, 'Sortings', True);
  for I := Low(ASortings) to High(ASortings) do
  begin
    SortingSubNode := AConfig.AddNode(SortingsNode, 'Sorting');
    AConfig.AddValue(SortingSubNode, 'Direction', Integer(ASortings[I].SortDirection));
    for J := Low(ASortings[I].SortFunctions) to High(ASortings[I].SortFunctions) do
      AConfig.AddValue(SortingSubNode, 'Function', Integer(ASortings[I].SortFunctions[J]));
  end;
end;

procedure LoadView(AConfig: TXmlConfig; ANode: TXmlNode;
  out AViewType: TDirectoryViewType; out AColumnSet: String);
var
  ViewNode: TXmlNode;
  ViewTypeName: String;
begin
  AViewType := dvtNone;
  AColumnSet := EmptyStr;

  ViewNode := AConfig.FindNode(ANode, 'View');
  if not Assigned(ViewNode) then Exit;

  if AConfig.TryGetAttr(ViewNode, 'Type', ViewTypeName) and
     TryStringToDirectoryViewType(ViewTypeName, AViewType) then
  begin
    if AViewType = dvtColumns then
      AColumnSet := AConfig.GetValue(ViewNode, 'ColumnsSet', 'Default');
  end;
end;

procedure SaveView(AConfig: TXmlConfig; ANode: TXmlNode;
  AViewType: TDirectoryViewType; const AColumnSet: String);
var
  ViewNode: TXmlNode;
begin
  if AViewType = dvtNone then Exit;

  ViewNode := AConfig.FindNode(ANode, 'View', True);
  AConfig.SetAttr(ViewNode, 'Type', DirectoryViewTypeToString(AViewType));
  if AViewType = dvtColumns then
    AConfig.SetValue(ViewNode, 'ColumnsSet', AColumnSet);
end;

{ TDirectorySettingsEntry }

destructor TDirectorySettingsEntry.Destroy;
begin
  FSortings := nil;
  inherited Destroy;
end;

function TDirectorySettingsEntry.HasSettings: Boolean;
begin
  Result := (Length(FSortings) > 0) or (FViewType <> dvtNone);
end;

{ TDirectorySettings }

constructor TDirectorySettings.Create;
begin
  inherited Create;
  FEntries := TStringList.Create;
  FEntries.Sorted := True;
  FEntries.CaseSensitive := FileNameCaseSensitive;
end;

destructor TDirectorySettings.Destroy;
begin
  Clear;
  FreeAndNil(FEntries);
  inherited Destroy;
end;

procedure TDirectorySettings.Clear;
var
  I: Integer;
begin
  for I := 0 to FEntries.Count - 1 do
    FEntries.Objects[I].Free;
  FEntries.Clear;
end;

function TDirectorySettings.FindEntry(const APath: String): TDirectorySettingsEntry;
var
  Index: Integer;
begin
  Result := nil;
  if FEntries.Find(NormalizePath(APath), Index) then
    Result := TDirectorySettingsEntry(FEntries.Objects[Index]);
end;

function TDirectorySettings.FindOrCreateEntry(const APath: String): TDirectorySettingsEntry;
var
  Index: Integer;
  NormalizedPath: String;
begin
  Result := nil;
  NormalizedPath := NormalizePath(APath);
  if NormalizedPath = EmptyStr then Exit;

  if FEntries.Find(NormalizedPath, Index) then
    Result := TDirectorySettingsEntry(FEntries.Objects[Index])
  else begin
    Result := TDirectorySettingsEntry.Create;
    FEntries.AddObject(NormalizedPath, Result);
  end;
end;

function TDirectorySettings.GetCount: Integer;
begin
  Result := FEntries.Count;
end;

function TDirectorySettings.NormalizePath(const APath: String): String;
begin
  Result := APath;
  if Result <> ExtractFileDrive(Result) + PathDelim then
    Result := ExcludeBackPathDelimiter(Result);
end;

procedure TDirectorySettings.LoadFromFile(const AFileName: String);
var
  AConfig: TXmlConfig;
  RootNode, DirectoryNode: TXmlNode;
  APath: String;
  ColumnSet: String;
  Entry: TDirectorySettingsEntry;
  ViewType: TDirectoryViewType;
begin
  Clear;
  if not mbFileExists(AFileName) then Exit;

  AConfig := TXmlConfig.Create(AFileName, True);
  try
    RootNode := AConfig.FindNode(AConfig.RootNode, 'DirectorySettings');
    if not Assigned(RootNode) then Exit;

    DirectoryNode := RootNode.FirstChild;
    while Assigned(DirectoryNode) do
    begin
      if DirectoryNode.CompareName('Directory') = 0 then
      begin
        if AConfig.TryGetAttr(DirectoryNode, 'Path', APath) then
        begin
          Entry := TDirectorySettingsEntry.Create;
          try
            Entry.Sortings := LoadSortings(AConfig, DirectoryNode);
            LoadView(AConfig, DirectoryNode, ViewType, ColumnSet);
            if Length(Entry.Sortings) > 0 then
              SetSorting(APath, Entry.Sortings);
            if ViewType <> dvtNone then
              SetView(APath, ViewType, ColumnSet);
          finally
            Entry.Free;
          end;
        end;
      end;
      DirectoryNode := DirectoryNode.NextSibling;
    end;
  finally
    AConfig.Free;
  end;
end;

procedure TDirectorySettings.SaveToFile(const AFileName: String);
var
  I: Integer;
  AConfig: TXmlConfig;
  RootNode, DirectoryNode: TXmlNode;
  Entry: TDirectorySettingsEntry;
begin
  AConfig := TXmlConfig.Create(AFileName);
  try
    RootNode := AConfig.FindNode(AConfig.RootNode, 'DirectorySettings', True);
    AConfig.ClearNode(RootNode);

    for I := 0 to FEntries.Count - 1 do
    begin
      Entry := TDirectorySettingsEntry(FEntries.Objects[I]);
      if Entry.HasSettings then
      begin
        DirectoryNode := AConfig.AddNode(RootNode, 'Directory');
        AConfig.SetAttr(DirectoryNode, 'Path', FEntries[I]);
        SaveSortings(AConfig, DirectoryNode, Entry.Sortings);
        SaveView(AConfig, DirectoryNode, Entry.ViewType, Entry.ColumnSet);
      end;
    end;
    AConfig.Save;
  finally
    AConfig.Free;
  end;
end;

function TDirectorySettings.TryGetSorting(const APath: String; out ASortings: TFileSortings): Boolean;
var
  Entry: TDirectorySettingsEntry;
begin
  ASortings := nil;
  Entry := FindEntry(APath);
  Result := Assigned(Entry) and (Length(Entry.Sortings) > 0);
  if Result then
    ASortings := CloneSortings(Entry.Sortings);
end;

function TDirectorySettings.TryGetView(const APath: String; out AViewType: TDirectoryViewType;
  out AColumnSet: String): Boolean;
var
  Entry: TDirectorySettingsEntry;
begin
  AViewType := dvtNone;
  AColumnSet := EmptyStr;
  Entry := FindEntry(APath);
  Result := Assigned(Entry) and (Entry.ViewType <> dvtNone);
  if Result then
  begin
    AViewType := Entry.ViewType;
    AColumnSet := Entry.ColumnSet;
  end;
end;

procedure TDirectorySettings.SetSorting(const APath: String; const ASortings: TFileSortings);
var
  Entry: TDirectorySettingsEntry;
begin
  Entry := FindOrCreateEntry(APath);
  if not Assigned(Entry) then Exit;

  Entry.Sortings := CloneSortings(ASortings);
end;

procedure TDirectorySettings.SetView(const APath: String; AViewType: TDirectoryViewType;
  const AColumnSet: String);
var
  Entry: TDirectorySettingsEntry;
begin
  Entry := FindOrCreateEntry(APath);
  if not Assigned(Entry) then Exit;

  Entry.ViewType := AViewType;
  if AViewType = dvtColumns then
    Entry.ColumnSet := AColumnSet
  else
    Entry.ColumnSet := EmptyStr;
end;

end.
