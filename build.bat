C:\VulkanSDK\1.3.243.0\Bin\glslc.exe .\shaders\day1\sum.comp -o .\out\shaders\day1\sum_comp.spv --target-env=vulkan1.3
C:\VulkanSDK\1.3.243.0\Bin\glslc.exe .\shaders\day1\sort.comp -o .\out\shaders\day1\sort_comp.spv --target-env=vulkan1.3
odin build day1 -out:out/day1.exe -debug -o:none
cp .\input\day1.txt .\out\input\day1.txt

C:\VulkanSDK\1.3.243.0\Bin\glslc.exe .\shaders\day2\score.comp -o .\out\shaders\day2\score.spv --target-env=vulkan1.3
odin build day2 -out:out/day2.exe -debug -o:none
cp .\input\day2.txt .\out\input\day2.txt