import QtQuick
import qs.Common
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "wallpaperCarouselWE"

    StringSetting {
        settingKey: "wallpaperDirectory"
        label: "Wallpaper Directory"
        description: "Override the wallpaper directory. Leave empty to automatically follow the current wallpaper's directory."
        placeholder: "/home/user/Pictures/Wallpapers"
        defaultValue: ""
    }

    SelectionSetting {
        settingKey: "carouselMode"
        label: "Carousel Mode"
        description: "Standard stops at the edges. Wrap loops the index. Infinite shows a seamless repeating view."
        defaultValue: "wrap"
        options: [
            { label: "Standard", value: "standard" },
            { label: "Wrap", value: "wrap" },
            { label: "Infinite", value: "infinite" }
        ]
    }

    SelectionSetting {
        settingKey: "swwwTransition"
        label: "Image Transition"
        description: "The swww transition effect used when picking a static image or GIF."
        defaultValue: "fade"
        options: [
            { label: "None",   value: "none"   },
            { label: "Simple", value: "simple" },
            { label: "Fade",   value: "fade"   },
            { label: "Left",   value: "left"   },
            { label: "Right",  value: "right"  },
            { label: "Top",    value: "top"    },
            { label: "Bottom", value: "bottom" },
            { label: "Wipe",   value: "wipe"   },
            { label: "Wave",   value: "wave"   },
            { label: "Grow",   value: "grow"   },
            { label: "Center", value: "center" },
            { label: "Outer",  value: "outer"  },
            { label: "Random", value: "random" }
        ]
    }

    SliderSetting {
        settingKey: "swwwTransitionFps"
        label: "Transition FPS"
        description: "Frame rate of the swww transition. Match this to your monitor refresh rate for smooth transitions."
        defaultValue: 60
        minimum: 15
        maximum: 360
        unit: " fps"
    }

    SliderSetting {
        settingKey: "swwwTransitionDuration"
        label: "Transition Duration"
        description: "How long the transition takes in seconds (does not apply to None/Simple)."
        defaultValue: 2
        minimum: 1
        maximum: 10
        unit: " s"
    }

    ListSettingWithInput {
        settingKey: "extraFolders"
        label: "Extra Wallpaper Folders"
        description: "Additional folders scanned for images in the Images tab. The primary folder is still derived from the current DMS wallpaper path."
        fields: [
            { id: "path", label: "Folder path", placeholder: "/home/user/Pictures/extra", required: true, width: 500 }
        ]
    }
}
