// Opts the Windows build into the Direct3D 12 Agility SDK in .\D3D12\ next to
// the executable (D3D12Core.dll, plus d3d12SDKLayers.dll for the debug layer).
// Debugging only: linked when the game is configured with
// -DCMAKE_PROJECT_INCLUDE=autoport/windows/d3d12_agility.cmake. The Agility
// debug layer still needs the "Graphics Tools" Windows feature: D3D12Core only
// loads d3d12SDKLayers.dll if it finds Graphics Tools' DXGIDebug.dll.
// The version must match the Agility SDK DLLs (Microsoft.Direct3D.D3D12 1.619.x).
extern "C" {
__declspec(dllexport) extern const unsigned int D3D12SDKVersion = 619;
__declspec(dllexport) extern const char* D3D12SDKPath = ".\\D3D12\\";
}
