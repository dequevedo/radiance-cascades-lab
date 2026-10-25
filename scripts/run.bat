@echo off
rem Opens the lab in a window (tunnel scene by default; free camera, keys 1-5 switch the GI method).
rem Set GODOT to your Godot 4.7 executable, or have "godot" on the PATH.  Usage:  .\scripts\run.bat [--scene=tunnel|street|room|shop]
if "%GODOT%"=="" set GODOT=godot
"%GODOT%" --path "%~dp0.." --rendering-driver vulkan -- %*
