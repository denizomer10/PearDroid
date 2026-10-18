// PearDroid – Swift ⇄ Vulkan (MoltenVK) bridge.
// Imported into every Swift file via -import-objc-header so that Vulkan types
// and entry points are available natively in Swift.
//
// ClangImporter parses this header in Objective-C mode, which makes
// vulkan_metal.h treat CAMetalLayer as an ObjC class. That turns
// VkMetalSurfaceCreateInfoEXT into a non-trivial Swift struct (no default
// initializer). We hide __OBJC__ while pulling in Vulkan so the struct stays a
// plain C record; we pass the CAMetalLayer as a raw pointer at call sites.
#ifndef PEARDROID_VULKAN_BRIDGE_H
#define PEARDROID_VULKAN_BRIDGE_H

#ifdef __OBJC__
#  define PD_RESTORE_OBJC 1
#  undef __OBJC__
#endif

#define VK_USE_PLATFORM_METAL_EXT 1
#include <vulkan/vulkan.h>

#ifdef PD_RESTORE_OBJC
#  undef PD_RESTORE_OBJC
#  define __OBJC__ 1
#endif

#endif
