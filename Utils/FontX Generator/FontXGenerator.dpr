program FontXGenerator;
{$I ..\..\KaM_Remake.inc}
uses
  Forms,
  Unit_Main in 'Unit_Main.pas' {Form1},
  KM_ResFonts in '..\..\KM_ResFonts.pas',
  KM_ResFontsEdit in '..\..\KM_ResFontsEdit.pas',
  CharsCollector in 'CharsCollector.pas';

begin
  Application.Initialize;
  {$IFDEF FPC} Application.MainFormOnTaskbar := True; {$ENDIF}
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
