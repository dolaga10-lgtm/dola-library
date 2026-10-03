require 'sketchup.rb'
require 'extensions.rb'

module DolaSmartLibraryPlugin
  unless file_loaded?(__FILE__)
    loader = SketchupExtension.new('مكتبة محمد عادل الذكية للمطابخ', 'DolaSmartLibrary/dola_library.rb')
    loader.description = 'مكتبة ذكية لمكونات المطابخ مع دعم العمل أوفلاين والمزامنة السحابية.'
    loader.version     = '1.0.0'
    loader.creator     = 'Mohamed Adel'

    Sketchup.register_extension(loader, true)
    file_loaded(__FILE__)
  end
end