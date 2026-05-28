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

  { TDirectorySettingsEntry }

  TDirectorySettingsEntry = class
  private
    FSortings: TFileSortings;
  public
    destructor Destroy; override;

    property Sortings: TFileSortings read FSortings write FSortings;
  end;

  { TDirectorySettings }

  TDirectorySettings = class
  private
    FEntries: TStringList;

    function FindEntry(const APath: String): TDirectorySettingsEntry;
    function GetCount: Integer;
    function NormalizePath(const APath: String): String;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    procedure LoadFromFile(const AFileName: String);
    procedure SaveToFile(const AFileName: String);
    function TryGetSorting(const APath: String; out ASortings: TFileSortings): Boolean;
    procedure SetSorting(const APath: String; const ASortings: TFileSortings);

    property Count: Integer read GetCount;
  end;

var
  gDirectorySettings: TDirectorySettings;

implementation

uses
  DCOSUtils, DCStrUtils;

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

{ TDirectorySettingsEntry }

destructor TDirectorySettingsEntry.Destroy;
begin
  FSortings := nil;
  inherited Destroy;
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
  Entry: TDirectorySettingsEntry;
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
            if Length(Entry.Sortings) > 0 then
              SetSorting(APath, Entry.Sortings);
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
      if Length(Entry.Sortings) > 0 then
      begin
        DirectoryNode := AConfig.AddNode(RootNode, 'Directory');
        AConfig.SetAttr(DirectoryNode, 'Path', FEntries[I]);
        SaveSortings(AConfig, DirectoryNode, Entry.Sortings);
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

procedure TDirectorySettings.SetSorting(const APath: String; const ASortings: TFileSortings);
var
  Index: Integer;
  NormalizedPath: String;
  Entry: TDirectorySettingsEntry;
begin
  NormalizedPath := NormalizePath(APath);
  if NormalizedPath = EmptyStr then Exit;

  if FEntries.Find(NormalizedPath, Index) then
    Entry := TDirectorySettingsEntry(FEntries.Objects[Index])
  else begin
    Entry := TDirectorySettingsEntry.Create;
    FEntries.AddObject(NormalizedPath, Entry);
  end;

  Entry.Sortings := CloneSortings(ASortings);
end;

end.
