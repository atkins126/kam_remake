unit KM_PlayerAI;
{$I KaM_Remake.inc}
interface
uses Classes, KM_CommonTypes, KM_Defaults, KromUtils, KM_Player, KM_Utils;

type
  TAIDefencePosType = (adt_FrontLine, //Top priority to defend, will be replaced by back line troops when they die
                       adt_BackLine); //Lower priority defence, can go on AI attacks

type
  TKMPlayerAI = class
  private
    Assets:TKMPlayerAssets; //This is just alias for Players assets
  public
    ReqWorkers, ReqSerfFactor, ReqRecruits: word; //Nunber of each unit type required
    RecruitTrainTimeout: Cardinal; //Recruits (for barracks) can only be trained after this many ticks
    TownDefence, MaxSoldiers, Aggressiveness: integer; //-1 means not use or default
    StartPosition: TKMPoint; //Defines roughly where to defend and build around
    Autobuild:boolean;
    TroopFormations: array[TGroupType] of record //Defines how defending troops will be formatted. 0 means leave unchanged.
                                            NumUnits, NumRows:integer;
                                          end;
    DefencePositions: array of record
                                 Position: TKMPointDir;
                                 GroupType: TGroupType;
                                 DefenceRadius: integer;
                                 DefenceType: TAIDefencePosType;
                               end;
    DefencePositionsCount: integer;
    constructor Create(aAssets:TKMPlayerAssets);
    procedure CheckGoals;
    procedure CheckUnitCount();
    procedure CheckArmy();
  public
    function GetHouseRepair:boolean; //Do we automatically repair all houses?
    procedure AddDefencePosition(aPos:TKMPointDir; aGroupType:TGroupType; aDefenceRadius:integer; aDefenceType:TAIDefencePosType);
    procedure Save(SaveStream:TKMemoryStream);
    procedure Load(LoadStream:TKMemoryStream);
    procedure SyncLoad();
    procedure UpdateState;
  end;

implementation
uses KM_Houses, KM_Units, KM_Units_Warrior, KM_Game, KM_PlayersCollection, KM_Settings, KM_LoadLib;

constructor TKMPlayerAI.Create(aAssets:TKMPlayerAssets);
begin
  Inherited Create;
  Assets := aAssets;
  DefencePositionsCount := 0;
  //Set some defaults (these are not measured from KaM)
  ReqWorkers := 3;
  ReqRecruits := 5; //This means the number in the barracks, watchtowers are counted seperately
  ReqSerfFactor := 10; //Means 1 serf per building
  RecruitTrainTimeout := 0; //Can train at start
  Autobuild := true; //In KaM it is on by default, and most missions turn it off
  StartPosition := KMPoint(0,0);
  MaxSoldiers := high(MaxSoldiers); //No limit by default
  TownDefence := 100; //In KaM 100 is standard, although we don't completely understand this command
  Aggressiveness := 100; //No idea what the default for this is, it's barely used
  FillChar(TroopFormations,SizeOf(TroopFormations),#0); //Leave format unchanged unless set by the mission file
end;


procedure TKMPlayerAI.CheckGoals;

  function GoalConditionSatisfied(aGoal: TPlayerGoal):boolean;
  var MS: TMissionSettings;
  begin
    Result := false;

    if aGoal.Player <> play_None then
      MS := fPlayers.Player[byte(aGoal.Player)].fMissionSettings
    else
      MS := nil; //Will trigger an error unless it's not gc_Time

    case aGoal.GoalCondition of //todo: add all goal condition checks properly and confirm unknowns with tests in KaM
      gc_BuildTutorial:     Result := MS.GetHouseQty(ht_Tannery)>0;
      gc_Time:              Result := fGame.CheckTime(aGoal.GoalTime);
      gc_Buildings:         Result := (MS.GetHouseQty(ht_Store)>0)or(MS.GetHouseQty(ht_School)>0)or(MS.GetHouseQty(ht_Barracks)>0);
      gc_Troops:            Result := (MS.GetArmyCount>0);
      gc_MilitaryAssets:    Result := (MS.GetArmyCount>0);
      gc_SerfsAndSchools:   Result := (MS.GetHouseQty(ht_School)>0)or(MS.GetUnitQty(ut_Serf)>0);
      gc_EconomyBuildings:  Result := ((MS.GetHouseQty(ht_Store)>0)or(MS.GetHouseQty(ht_School)>0)or(MS.GetHouseQty(ht_Inn)>0));
      else                  Assert(false, 'Unknown goal');
    end;
    if aGoal.GoalStatus = gs_False then
      Result := not Result; //Reverse condition
  end;

var i: integer; VictorySatisfied, SurvivalSatisfied: boolean;
begin
  if not CHECK_WIN_CONDITIONS then exit;

  if fGame.PlayOnState <> gr_Cancel then exit; //If player has elected to play on past victory or defeat then do not check for any further goals
  
  VictorySatisfied  := true; //Assume they will win/survive, then prove it with goals
  SurvivalSatisfied := true;

  with Assets do
  for i:=0 to fGoalCount-1 do //Test each goal to see if it has occured
    if GoalConditionSatisfied(fGoals[i]) then
    begin
      //Display message if set and not already shown and not a blank text
      if (fGoals[i].MessageToShow <> 0) and (not fGoals[i].MessageHasShown) and (fTextLibrary.GetTextString(fGoals[i].MessageToShow) <> '') then
      begin
        fGame.fGameplayInterface.MessageIssue(msgText,fTextLibrary.GetTextString(fGoals[i].MessageToShow),KMPoint(0,0));
        fGoals[i].MessageHasShown := true;
      end;
    end
    else
    begin
      if fGoals[i].GoalType = glt_Victory then
        VictorySatisfied := false;
      if fGoals[i].GoalType = glt_Survive then
        SurvivalSatisfied := false;
    end;

  if VictorySatisfied then
    fGame.GameHold(true, gr_Win); //They win

  if not SurvivalSatisfied then
    fGame.GameHold(true, gr_Defeat); //They lose
end;


{ Check existing unit count vs house count and train missing citizens }
procedure TKMPlayerAI.CheckUnitCount();
var
  i,k:integer;
  UnitType:TUnitType;
  HS:TKMHouseSchool;
  UnitReq:array[1..HOUSE_COUNT]of integer; //There are only ~10 unit types, but using HOUSE_COUNT is easier
  Schools:array of TKMHouseSchool;

  function CheckUnitRequirements(Req:integer; aUnitType:TUnitType):boolean;
  begin
    if Assets.GetUnitQty(aUnitType) < (Req+UnitReq[integer(aUnitType)]) then
    begin
      dec(UnitReq[integer(aUnitType)]); //So other schools don't order same unit
      HS.AddUnitToQueue(aUnitType);
      Result := true;
    end
    else
      Result := false;
  end;
begin
  //Find school and make sure it's free of tasks
  FillChar(UnitReq,SizeOf(UnitReq),#0); //Clear up

  //Citizens
  for i:=1 to HOUSE_COUNT do begin //Count overall unit requirement
    if THouseType(i)<>ht_Barracks then //Exclude Barracks
    if HouseDAT[i].OwnerType<>-1 then //Exclude houses without owners
    inc(UnitReq[HouseDAT[i].OwnerType+1], Assets.GetHouseQty(THouseType(i)));
  end;

  SetLength(Schools,Assets.GetHouseQty(ht_School));
  k := 1;
  HS := TKMHouseSchool(Assets.FindHouse(ht_School,k));
  while HS <> nil do
  begin
    Schools[k-1] := HS;
    if HS.UnitQueue[1]<>ut_None then
      dec(UnitReq[integer(HS.UnitQueue[1])]); //Decrease requirement for each unit in training
    inc(k);
    HS := TKMHouseSchool(Assets.FindHouse(ht_School,k));
  end;

  for k:=1 to Length(Schools) do
  begin
    HS := Schools[k-1];
    if (HS<>nil)and(HS.UnitQueue[1]=ut_None) then
    begin
      for i:=1 to length(UnitReq) do
        if UnitReq[i] > Assets.GetUnitQty(TUnitType(i)) then
        begin
          UnitType := TUnitType(i);
          if UnitType <> ut_None then
          begin
            dec(UnitReq[i]); //So other schools don't order same unit
            HS.AddUnitToQueue(UnitType);
            break; //Don't need more UnitTypes yet
          end;
        end;
      //If we are here then a citizen to train wasn't found, so try other unit types (citizens get top priority)
      //Serf factor is like this: Serfs = (10/FACTOR)*Total_Building_Count) (from: http://atfreeforum.com/knights/viewtopic.php?t=465)
      if (HS.UnitQueue[1] = ut_None) then //Still haven't found a match...
        if not CheckUnitRequirements(Round((10/ReqSerfFactor)*Assets.GetHouseQty(ht_None)), ut_Serf) then //todo: consider replacing with GetHouseCount
          if not CheckUnitRequirements(ReqWorkers, ut_Worker) then
            if fGame.CheckTime(RecruitTrainTimeout) then //Recruits can only be trained after this time
              CheckUnitRequirements(ReqRecruits, ut_Recruit);
    end;
  end;
end;


procedure TKMPlayerAI.CheckArmy();
var i: integer;
    NeedsLinkingTo: array[TGroupType] of TKMUnitWarrior;
begin
  //Iterate units list in search of warrior commanders, and then check the following: Hunger, (feed) formation, (units per row) position (from defence positions)
  for i:=0 to Assets.GetUnits.Count-1 do
  begin
    if TKMUnit(Assets.GetUnits.Items[i]) is TKMUnitWarrior then
      with TKMUnitWarrior(Assets.GetUnits.Items[i]) do
        if (fCommander = nil) and not IsDead then
        begin
          //Check hunger and feed
          if (GetCondition < UNIT_MIN_CONDITION) then
            OrderFood;

          //If we are newly trained then link us up to a group which doesn't have enough members
          //...

          //Check formation
          if UnitGroups[byte(GetUnitType)] <> gt_None then
          begin
            if TroopFormations[UnitGroups[byte(GetUnitType)]].NumRows > 1 then
              UnitsPerRow := TroopFormations[UnitGroups[byte(GetUnitType)]].NumRows;
            //If this group doesn't have enough members, flag us as needing to be added to (this should not happen if we are attacking though)
            if (GetMemberCount < TroopFormations[UnitGroups[byte(GetUnitType)]].NumUnits) and
              (NeedsLinkingTo[UnitGroups[byte(GetUnitType)]] = nil) then
              NeedsLinkingTo[UnitGroups[byte(GetUnitType)]] := TKMUnitWarrior(Assets.GetUnits.Items[i]);
          end;

          //todo: Check position and arrange groups according to Defence Positions from mission file
        end;
  end;
end;


//Do we automatically repair all houses?
//For now use Autobuild, which is what KaM does. Later we can add a script command to turn this on and off
//Also could be changed later to disable repairing when under attack? (only repair if the enemy goes away?)
function TKMPlayerAI.GetHouseRepair:boolean;
begin
  Result := Autobuild;
end;


procedure TKMPlayerAI.AddDefencePosition(aPos:TKMPointDir; aGroupType:TGroupType; aDefenceRadius:integer; aDefenceType:TAIDefencePosType);
begin
  setlength(DefencePositions,DefencePositionsCount+1);
  DefencePositions[DefencePositionsCount].Position := aPos;
  DefencePositions[DefencePositionsCount].GroupType := aGroupType;
  DefencePositions[DefencePositionsCount].DefenceRadius := aDefenceRadius;
  DefencePositions[DefencePositionsCount].DefenceType := aDefenceType;
  inc(DefencePositionsCount);
end;


procedure TKMPlayerAI.Save(SaveStream:TKMemoryStream);
var i: integer;
begin
  SaveStream.Write(ReqWorkers);
  SaveStream.Write(ReqSerfFactor);
  SaveStream.Write(ReqRecruits);
  SaveStream.Write(RecruitTrainTimeout);
  SaveStream.Write(TownDefence);
  SaveStream.Write(MaxSoldiers);
  SaveStream.Write(Aggressiveness);
  SaveStream.Write(StartPosition);
  SaveStream.Write(Autobuild);
  SaveStream.Write(TroopFormations,SizeOf(TroopFormations));
  SaveStream.Write(DefencePositionsCount);
  for i:=0 to DefencePositionsCount-1 do
    SaveStream.Write(DefencePositions[i], SizeOf(DefencePositions[i]));
end;


procedure TKMPlayerAI.Load(LoadStream:TKMemoryStream);
var i: integer;
begin
  LoadStream.Read(ReqWorkers);
  LoadStream.Read(ReqSerfFactor);
  LoadStream.Read(ReqRecruits);
  LoadStream.Read(RecruitTrainTimeout);
  LoadStream.Read(TownDefence);
  LoadStream.Read(MaxSoldiers);
  LoadStream.Read(Aggressiveness);
  LoadStream.Read(StartPosition);
  LoadStream.Read(Autobuild);
  LoadStream.Read(TroopFormations,SizeOf(TroopFormations));
  LoadStream.Read(DefencePositionsCount);
  SetLength(DefencePositions, DefencePositionsCount);
  for i:=0 to DefencePositionsCount-1 do
    LoadStream.Read(DefencePositions[i], SizeOf(DefencePositions[i]));
end;


//So far this whole procedure is a placeholder
procedure TKMPlayerAI.SyncLoad();
begin
  //
end;                      


procedure TKMPlayerAI.UpdateState;
begin
  //Check goals only for MyPlayer
  if (MyPlayer=Assets)and(Assets.PlayerType=pt_Human) then
  begin
    CheckGoals; //This procedure manages victory, loss and messages all in one
  end
  else
  if Assets.PlayerType=pt_Computer then
  begin
    CheckUnitCount; //Train new units (citizens, serfs, workers and recruits) if needed

    CheckArmy; //todo: Should not run every update state, it takes too long and doesn't need to anyway
    //CheckHouseCount; //Build new houses if needed
    //CheckArmiesCount; //Train new soldiers if needed
    //CheckEnemyPresence; //Check enemy threat in close range and issue defensive attacks (or flee?)
    //CheckAndIssueAttack; //Attack enemy
    //Anything Else?
  end;
end;

end.
