@echo off
rem Opens the grocery-store scene with the control panel (the quote key, above Tab, frees the mouse for the panel).
rem Set GODOT to your Godot 4.7 executable, or have "godot" on the PATH.  Usage:  .\scripts\run_shop.bat
if "%GODOT%"=="" set GODOT=godot
"%GODOT%" --path "%~dp0.." --rendering-driver vulkan -- --scene=shop
