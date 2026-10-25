@echo off
rem Opens the lab in a window. Set GODOT to your Godot 4.7 executable, or have "godot" on the PATH.  Usage:  .\scripts\run.bat
if "%GODOT%"=="" set GODOT=godot
"%GODOT%" --path "%~dp0.." --rendering-driver vulkan -- %*
