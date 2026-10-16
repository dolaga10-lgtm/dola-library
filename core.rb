# encoding: UTF-8
# ==============================================================================
#  مكتبة محمد عادل الذكية (المطابخ والدريسنج) — الملف الرئيسي للأدوات (core.rb)
#  يتم رفعه في المسار الرئيسي للمستودع:
#  https://raw.githubusercontent.com/dolaga10-lgtm/dola-library/refs/heads/main/core.rb
# ==============================================================================

require 'sketchup.rb'
require 'json'
require 'cgi'
require 'uri'
require 'tmpdir'
require 'fileutils'
begin
  require 'zlib'
rescue LoadError
end

module DolaSmartLibraryPlugin

  CORE_VERSION      = '2.7.0'.freeze unless const_defined?(:CORE_VERSION, false)
  PREF_NS           = 'DolaSmartLibrary'.freeze unless const_defined?(:PREF_NS, false)
  GRAIN_DICT        = 'DolaWoodGrain'.freeze unless const_defined?(:GRAIN_DICT, false)
  RELIEF_DICT       = 'DolaWallRelief'.freeze unless const_defined?(:RELIEF_DICT, false)
  OCL_DICT          = 'ladb_opencutlist'.freeze unless const_defined?(:OCL_DICT, false)
  LIBRARY_META_DICT = 'DolaLibraryMeta'.freeze unless const_defined?(:LIBRARY_META_DICT, false)

  def self.clean_library_unit_name(raw_str)
    return '' if raw_str.nil?
    s = raw_str.to_s.split('?').first.to_s.strip
    s = s.split('/').last.to_s if s.include?('/')
    s = s.split('\\').last.to_s if s.include?('\\')
    begin
      s = URI.decode_www_form_component(s)
    rescue
      s = URI::DEFAULT_PARSER.unescape(s).gsub('+', ' ') rescue s
    end
    s = s.sub(/\.(skp|glb)\z/i, '')
    s = s.gsub(/\s*\([^)]*\)/, '')
    s = s.sub(/#\d+\z/, '').strip
    generic = [
      'base_unit', 'wall_unit', 'tall_unit', 'corner_unit',
      'component', 'main component', 'المكون الرئيسي', 'مكون رئيسي', 'وحدة مطبخ'
    ]
    return '' if s.empty? || generic.any? { |g| s.downcase == g || s.downcase.start_with?("#{g}#") || s.downcase.start_with?("#{g}_") }
    s
  rescue
    ''
  end

  def self.resolve_library_unit_display_name(unit)
    return 'وحدة مطبخ' unless unit && unit.valid?

    candidates = []
    candidates << unit.get_attribute(LIBRARY_META_DICT, 'unit_display_name', nil)
    if unit.respond_to?(:definition) && unit.definition
      candidates << unit.definition.get_attribute(LIBRARY_META_DICT, 'unit_display_name', nil)
      candidates << unit.definition.path unless unit.definition.path.to_s.strip.empty?
    end
    candidates << unit.name
    candidates << unit.get_attribute('dynamic_attributes', '_name', nil)
    if unit.respond_to?(:definition) && unit.definition
      candidates << unit.definition.name
      candidates << unit.definition.get_attribute('dynamic_attributes', '_name', nil)
    end

    candidates.each do |c|
      cleaned = clean_library_unit_name(clean_dc_label(c.to_s))
      return cleaned unless cleaned.empty?
    end

    'وحدة مطبخ'
  rescue
    'وحدة مطبخ'
  end

  # ============================================================================
  #  فحص وفك غلاف المكونات الديناميكية بأمان تام مع حفظ اسم الوحدة من المكتبة
  # ============================================================================
  def self.dynamic?(instance)
    return false unless instance.is_a?(Sketchup::ComponentInstance)
    return true if instance.attribute_dictionary('dynamic_attributes', false)
    return true if instance.definition && instance.definition.attribute_dictionary('dynamic_attributes', false)
    false
  rescue
    false
  end

  def self.unwrap_to_dynamic!(instance)
    return instance unless instance && instance.valid? && instance.is_a?(Sketchup::ComponentInstance)

    saved_lib_name = clean_library_unit_name(instance.get_attribute(LIBRARY_META_DICT, 'unit_display_name', nil))
    if saved_lib_name.empty? && instance.definition
      saved_lib_name = clean_library_unit_name(instance.definition.get_attribute(LIBRARY_META_DICT, 'unit_display_name', nil))
      saved_lib_name = clean_library_unit_name(instance.definition.path) if saved_lib_name.empty?
      saved_lib_name = clean_library_unit_name(instance.definition.name) if saved_lib_name.empty?
    end

    if dynamic?(instance)
      unless saved_lib_name.empty?
        instance.set_attribute(LIBRARY_META_DICT, 'unit_display_name', saved_lib_name) rescue nil
        instance.name = saved_lib_name rescue nil
      end
      return instance
    end

    ents   = instance.definition.entities.to_a
    childs = ents.grep(Sketchup::ComponentInstance)
    groups = ents.grep(Sketchup::Group)
    faces  = ents.grep(Sketchup::Face)

    # لا نفك الغلاف إلا إذا كان الملف الخارجي مجرد غلاف فارغ يحتوي على كمبوننت رئيسي واحد فقط بداخله
    return instance unless childs.length == 1 && groups.empty? && faces.empty?
    return instance unless dynamic?(childs.first)

    model = Sketchup.active_model
    model.start_operation('Unwrap Dynamic Component', true)
    begin
      parent_ents = instance.parent.entities
      before_ids  = parent_ents.to_a.map(&:entityID)

      instance.explode

      after = parent_ents.to_a.reject { |e| before_ids.include?(e.entityID) }
      after_insts = after.grep(Sketchup::ComponentInstance)

      dyn = after_insts.find { |x| dynamic?(x) } || after_insts.first
      if dyn && dyn.valid? && !saved_lib_name.empty?
        dyn.set_attribute(LIBRARY_META_DICT, 'unit_display_name', saved_lib_name) rescue nil
        dyn.definition.set_attribute(LIBRARY_META_DICT, 'unit_display_name', saved_lib_name) rescue nil
        dyn.name = saved_lib_name rescue nil
      end
      model.selection.clear
      model.selection.add(dyn) if dyn
      model.commit_operation
      dyn || instance
    rescue
      model.abort_operation rescue nil
      instance
    end
  end

  # ============================================================================
  #  قائمة الأدوات الـ 14 الموحدة مع أيقونات SVG ملونة ومميزة لكل أداة
  # ============================================================================
  CORE_TOOLS_SPEC = [
    {
      :id      => 'draw_walls',
      :title   => 'رسم الحوائط',
      :short   => 'رسم الحوائط',
      :tooltip => 'رسم حوائط الغرفة بالقياسات: ادخل السمك والارتفاع ثم طول كل ضلع، مع زاوية بالمثلث (ضلعين + وتر) وإغلاق تلقائي عند نقطة البداية وإمكانية التوقف عند الباب',
      :group   => 'walls',
      :rgb     => [192, 38, 211],
      :bg_grad => 'linear-gradient(135deg, #d946ef 0%, #86198f 100%)',
      :symbol  => :walls,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polygon points="3,21 3,3 21,3 21,7.4 7.4,7.4 7.4,21" fill="#ffffff" fill-opacity="0.26" stroke="#ffffff" stroke-width="1.8"/><polyline points="10.6,10.6 14.8,10.6 14.8,14.8" fill="none" stroke="#fde047" stroke-width="1.6"/><polyline points="14.2,20.4 20.8,13.8" fill="none" stroke="#fde047" stroke-width="3.6"/><polygon points="13.2,21.4 11.4,22.6 12.6,20.6" fill="#ffffff" fill-opacity="1" stroke="#ffffff" stroke-width="1.4"/></svg>'
    },
    {
      :id      => 'component_options',
      :title   => 'خيارات الوحدة',
      :short   => 'خيارات الوحدة',
      :tooltip => 'فتح نافذة خيارات ومقاسات الوحدة المحددة + الخلع والعمود (بديل Component Options)',
      :group   => 'main',
      :rgb     => [2, 132, 199],
      :bg_grad => 'linear-gradient(135deg, #0284c7 0%, #1d4ed8 100%)',
      :symbol  => :gear,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polyline points="4,6 20,6" fill="none" stroke="#ffffff" stroke-width="2"/><polyline points="4,12 20,12" fill="none" stroke="#ffffff" stroke-width="2"/><polyline points="4,18 20,18" fill="none" stroke="#ffffff" stroke-width="2"/><circle cx="9" cy="6" r="2.4" fill="#fde047" fill-opacity="1" stroke="none"/><circle cx="15.5" cy="12" r="2.4" fill="#fde047" fill-opacity="1" stroke="none"/><circle cx="8" cy="18" r="2.4" fill="#fde047" fill-opacity="1" stroke="none"/></svg>'
    },
    {
      :id      => 'wood_grain_show_all',
      :title   => 'بيان اتجاه الثمرة',
      :short   => 'بيان اتجاه الثمرة',
      :tooltip => 'إظهار/إخفاء علامات اتجاه الثمرة لكل قطع الوحدة شاملة الضهريات (تظهر علامتها فوق الوحدة) مع إمكانية التعديل الفوري',
      :group   => 'grain',
      :rgb     => [217, 119, 6],
      :bg_grad => 'linear-gradient(135deg, #d97706 0%, #92400e 100%)',
      :symbol  => :grain_z,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polygon points="2.5,10 3.09,9.26 3.73,8.58 4.42,7.97 5.16,7.42 5.93,6.93 6.73,6.51 7.57,6.16 8.43,5.87 9.3,5.64 10.19,5.48 11.09,5.38 12,5.35 12.91,5.38 13.81,5.48 14.7,5.64 15.57,5.87 16.43,6.16 17.27,6.51 18.07,6.93 18.84,7.42 19.58,7.97 20.27,8.58 20.91,9.26 21.5,10 20.91,10.74 20.27,11.42 19.58,12.03 18.84,12.58 18.07,13.07 17.27,13.49 16.43,13.84 15.57,14.13 14.7,14.36 13.81,14.52 12.91,14.62 12,14.65 11.09,14.62 10.19,14.52 9.3,14.36 8.43,14.13 7.57,13.84 6.73,13.49 5.93,13.07 5.16,12.58 4.42,12.03 3.73,11.42 3.09,10.74 2.5,10" fill="#ffffff" fill-opacity="0.1" stroke="#ffffff" stroke-width="1.9"/><circle cx="12" cy="10" r="2.6" fill="#fde047" fill-opacity="1" stroke="none"/><polyline points="8,18.4 8,22" fill="none" stroke="#fde047" stroke-width="1.7"/><polyline points="12,18.4 12,22" fill="none" stroke="#fde047" stroke-width="1.7"/><polyline points="16,18.4 16,22" fill="none" stroke="#fde047" stroke-width="1.7"/></svg>'
    },
    {
      :id      => 'wood_grain_single_tool',
      :title   => 'قلب ثمرة قطعة (يدوي)',
      :short   => 'قلب ثمرة قطعة',
      :tooltip => 'أداة تفاعلية بكاشف بصري لقلب ثمرة أي قطعة خشبية بين أكبر مقاسين (الطول ⇄ العرض) بدون لمس السماكة',
      :group   => 'grain',
      :rgb     => [234, 88, 12],
      :bg_grad => 'linear-gradient(135deg, #f97316 0%, #c2410c 100%)',
      :symbol  => :grain_flip,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polyline points="8,20 8,5" fill="none" stroke="#fde047" stroke-width="2.3"/><polyline points="5.3,7.82 8,4.6 10.7,7.82" fill="none" stroke="#fde047" stroke-width="2.3"/><polyline points="16,4 16,19" fill="none" stroke="#ffffff" stroke-width="2.3"/><polyline points="18.7,16.18 16,19.4 13.3,16.18" fill="none" stroke="#ffffff" stroke-width="2.3"/></svg>'
    },
    {
      :id      => 'rotate90',
      :title   => 'تدوير الوحدة 45°',
      :short   => 'تدوير 45°',
      :tooltip => 'أداة تدوير أي وحدة 45 درجة حول مركزها بالضغط عليها',
      :group   => 'transform',
      :rgb     => [14, 165, 233],
      :bg_grad => 'linear-gradient(135deg, #0ea5e9 0%, #0369a1 100%)',
      :symbol  => :rotate,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polyline points="19.45,7.7 19.79,8.37 20.08,9.06 20.31,9.77 20.47,10.51 20.57,11.25 20.6,12 20.57,12.75 20.47,13.49 20.31,14.23 20.08,14.94 19.79,15.63 19.45,16.3 19.04,16.93 18.59,17.53 18.08,18.08 17.53,18.59 16.93,19.04 16.3,19.45 15.63,19.79 14.94,20.08 14.23,20.31 13.49,20.47 12.75,20.57 12,20.6 11.25,20.57 10.51,20.47 9.77,20.31 9.06,20.08 8.37,19.79 7.7,19.45 7.07,19.04 6.47,18.59 5.92,18.08 5.41,17.53 4.96,16.93 4.55,16.3 4.21,15.63 3.92,14.94 3.69,14.23 3.53,13.49 3.43,12.75 3.4,12 3.43,11.25 3.53,10.51 3.69,9.77 3.92,9.06 4.21,8.37 4.55,7.7 4.96,7.07 5.41,6.47 5.92,5.92 6.47,5.41 7.07,4.96 7.7,4.55 8.37,4.21 9.06,3.92" fill="none" stroke="#ffffff" stroke-width="2.1"/><polyline points="5.32,3.26 9.06,3.92 6.62,6.83" fill="none" stroke="#ffffff" stroke-width="2.1"/><text x="12" y="12.4" fill="#fde047" stroke="none" font-size="7.4" font-weight="800" font-family="Tahoma,Arial,sans-serif" text-anchor="middle" dominant-baseline="central">45°</text></svg>'
    },
    {
      :id      => 'flip_lr',
      :title   => 'قلب يمين / شمال',
      :short   => 'قلب يمين/شمال',
      :tooltip => 'أداة قلب ومرايا الوحدة يمين/شمال بالضغط عليها',
      :group   => 'transform',
      :rgb     => [139, 92, 246],
      :bg_grad => 'linear-gradient(135deg, #8b5cf6 0%, #6d28d9 100%)',
      :symbol  => :flip,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polyline points="12,2.5 12,21.5" fill="none" stroke="#fde047" stroke-width="1.6" stroke-dasharray="2.4 2.4"/><polygon points="3.5,19 9.5,5 9.5,19" fill="#ffffff" fill-opacity="0.2" stroke="#ffffff" stroke-width="1.9"/><polygon points="20.5,19 14.5,5 14.5,19" fill="#fde047" fill-opacity="0.38" stroke="#fde047" stroke-width="1.9"/></svg>'
    },
    {
      :id      => 'snap_side',
      :title   => 'لزق جنب بجنب (Snap)',
      :short   => 'لزق جنب بجنب',
      :tooltip => 'أداة محاذاة ولزق وحدة بجانب وحدة أخرى تلقائياً (Click Side Snap)',
      :group   => 'transform',
      :rgb     => [16, 185, 129],
      :bg_grad => 'linear-gradient(135deg, #10b981 0%, #047857 100%)',
      :symbol  => :snap,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polyline points="6.5,4.5 6.5,12 6.53,12.57 6.62,13.14 6.77,13.7 6.98,14.24 7.24,14.75 7.55,15.23 7.91,15.68 8.32,16.09 8.77,16.45 9.25,16.76 9.76,17.02 10.3,17.23 10.86,17.38 11.43,17.47 12,17.5 12.57,17.47 13.14,17.38 13.7,17.23 14.24,17.02 14.75,16.76 15.23,16.45 15.68,16.09 16.09,15.68 16.45,15.23 16.76,14.75 17.02,14.24 17.23,13.7 17.38,13.14 17.47,12.57 17.5,12 17.5,4.5" fill="none" stroke="#ffffff" stroke-width="4.2"/><polyline points="6.5,4.5 6.5,8" fill="none" stroke="#fde047" stroke-width="4.2"/><polyline points="17.5,4.5 17.5,8" fill="none" stroke="#fde047" stroke-width="4.2"/><polyline points="12,2.2 12,5.6" fill="none" stroke="#fde047" stroke-width="1.5"/><polyline points="9.6,3.2 10.8,5.7" fill="none" stroke="#fde047" stroke-width="1.5"/><polyline points="14.4,3.2 13.2,5.7" fill="none" stroke="#fde047" stroke-width="1.5"/><polyline points="6,21 18,21" fill="none" stroke="#ffffff" stroke-width="1.6" stroke-dasharray="1.2 2.4"/></svg>'
    },
    {
      :id      => 'classic_door',
      :title   => 'تبديل الضلفة',
      :short   => 'تبديل الضلفة',
      :tooltip => 'تبديل شكل وتصميم الضلفة (سادة مودرن / شيكر كلاسيك / زجاج / مقبض مخفي)',
      :group   => 'kitchen',
      :rgb     => [219, 39, 119],
      :bg_grad => 'linear-gradient(135deg, #ec4899 0%, #be185d 100%)',
      :symbol  => :door,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2.5" width="12" height="19" rx="1.6" fill="#ffffff" fill-opacity="0.12" stroke="#ffffff" stroke-width="1.9"/><rect x="8.6" y="5.2" width="6.4" height="5.6" rx="0.8" fill="none" stroke="#ffffff" stroke-width="1.3"/><rect x="8.6" y="12.4" width="6.4" height="5.6" rx="0.8" fill="none" stroke="#ffffff" stroke-width="1.3"/><circle cx="16.3" cy="12" r="1.1" fill="#fde047" fill-opacity="1" stroke="none"/></svg>'
    },
    {
      :id      => 'hand_groove',
      :title   => 'حفر ليد (LED Groove)',
      :short   => 'حفر ليد LED',
      :tooltip => 'إضافة أو حفر مجرى بروفايل الإضاءة الليد في الوحدات العلوية أو الدواليب',
      :group   => 'kitchen',
      :rgb     => [234, 179, 8],
      :bg_grad => 'linear-gradient(135deg, #eab308 0%, #a16207 100%)',
      :symbol  => :led,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="10" r="5.2" fill="#fde047" fill-opacity="0.32" stroke="#ffffff" stroke-width="1.9"/><polyline points="9.7,14.4 10.2,17.4" fill="none" stroke="#ffffff" stroke-width="1.9"/><polyline points="14.3,14.4 13.8,17.4" fill="none" stroke="#ffffff" stroke-width="1.9"/><polyline points="10.2,17.4 13.8,17.4" fill="none" stroke="#ffffff" stroke-width="1.9"/><polyline points="10.7,19.8 13.3,19.8" fill="none" stroke="#ffffff" stroke-width="1.9"/><polyline points="11.3,22 12.7,22" fill="none" stroke="#ffffff" stroke-width="1.7"/><polyline points="10.5,12.6 10.5,9.8 12,11.2 13.5,9.8 13.5,12.6" fill="none" stroke="#fde047" stroke-width="1.4"/><polyline points="12,2.7 12,0.8" fill="none" stroke="#fde047" stroke-width="1.7"/><polyline points="6.84,4.84 5.49,3.49" fill="none" stroke="#fde047" stroke-width="1.7"/><polyline points="17.16,4.84 18.51,3.49" fill="none" stroke="#fde047" stroke-width="1.7"/><polyline points="4.7,10 2.8,10" fill="none" stroke="#fde047" stroke-width="1.7"/><polyline points="19.3,10 21.2,10" fill="none" stroke="#fde047" stroke-width="1.7"/></svg>'
    },
    {
      :id      => 'kitchen_materials',
      :title   => 'مستويات وخامات المطبخ',
      :short   => 'خامات المطبخ',
      :tooltip => 'إدارة وتعديل أسماء وألوان ونقشات الخامات للمستويات والـ CutList',
      :group   => 'kitchen',
      :rgb     => [225, 29, 72],
      :bg_grad => 'linear-gradient(135deg, #f43f5e 0%, #9f1239 100%)',
      :symbol  => :palette,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.2" fill="#ffffff" fill-opacity="0.1" stroke="#ffffff" stroke-width="1.9"/><circle cx="15.4" cy="16.4" r="2.1" fill="none" stroke="#ffffff" stroke-width="1.5"/><circle cx="7.8" cy="10.6" r="1.6" fill="#fde047" fill-opacity="1" stroke="none"/><circle cx="11.2" cy="6.9" r="1.6" fill="#67e8f9" fill-opacity="1" stroke="none"/><circle cx="16" cy="8.6" r="1.6" fill="#f9a8d4" fill-opacity="1" stroke="none"/><circle cx="7.6" cy="15.3" r="1.6" fill="#86efac" fill-opacity="1" stroke="none"/></svg>'
    },
    {
      :id      => 'serial_tool',
      :title   => 'ترقيم الوحدات',
      :short   => 'ترقيم الوحدات',
      :tooltip => 'ترقيم وحدات المطبخ والدريسنج تسلسلياً للتقارير والـ Cutting List',
      :group   => 'utility',
      :rgb     => [79, 70, 229],
      :bg_grad => 'linear-gradient(135deg, #6366f1 0%, #3730a3 100%)',
      :symbol  => :serial,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polyline points="9.2,3.5 9.2,20.5" fill="none" stroke="#ffffff" stroke-width="2.1"/><polyline points="14.8,3.5 14.8,20.5" fill="none" stroke="#ffffff" stroke-width="2.1"/><polyline points="4,9 20,9" fill="none" stroke="#fde047" stroke-width="2.1"/><polyline points="4,15 20,15" fill="none" stroke="#fde047" stroke-width="2.1"/></svg>'
    },
    {
      :id      => 'unique',
      :title   => 'جعل الكمبوننتات فريدة',
      :short   => 'كمبوننتات فريدة',
      :tooltip => 'فك ارتباط جميع الكمبوننتات المحددة أو في المشروع وجعل كل منها فريداً (Make Unique)',
      :group   => 'utility',
      :rgb     => [13, 148, 136],
      :bg_grad => 'linear-gradient(135deg, #14b8a6 0%, #0f766e 100%)',
      :symbol  => :unique,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3.5" width="11" height="11" rx="1.5" fill="none" stroke="#ffffff" stroke-width="1.7" stroke-dasharray="2.4 2.4"/><rect x="9.5" y="9.5" width="11" height="11" rx="1.5" fill="#fde047" fill-opacity="0.28" stroke="#fde047" stroke-width="2"/><text x="15" y="15.3" fill="#ffffff" stroke="none" font-size="8.5" font-weight="800" font-family="Tahoma,Arial,sans-serif" text-anchor="middle" dominant-baseline="central">1</text></svg>'
    },
    {
      :id      => 'component_translator',
      :title   => 'ترجمة أسماء القطع',
      :short   => 'ترجمة القطع',
      :tooltip => 'ترجمة وتعريب أسماء جميع القطع الداخلية للوحدات لتظهر بالعربية في الـ Cutting List',
      :group   => 'utility',
      :rgb     => [8, 145, 178],
      :bg_grad => 'linear-gradient(135deg, #06b6d4 0%, #155e75 100%)',
      :symbol  => :translate,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polyline points="12.5,5.2 20,5.2" fill="none" stroke="#fde047" stroke-width="1.5"/><polyline points="18.06,3.4 20.2,5.2 18.06,7" fill="none" stroke="#fde047" stroke-width="1.5"/><polyline points="11.5,20 4,20" fill="none" stroke="#ffffff" stroke-width="1.5"/><polyline points="5.94,21.8 3.8,20 5.94,18.2" fill="none" stroke="#ffffff" stroke-width="1.5"/><text x="7.6" y="12.6" fill="#ffffff" stroke="none" font-size="10.5" font-weight="800" font-family="Tahoma,Arial,sans-serif" text-anchor="middle" dominant-baseline="central">A</text><text x="16.6" y="12.9" fill="#fde047" stroke="none" font-size="11.5" font-weight="800" font-family="Tahoma,Arial,sans-serif" text-anchor="middle" dominant-baseline="central">ع</text></svg>'
    },
    {
      :id      => 'report',
      :title   => 'إنشاء تقرير الوحدات',
      :short   => 'تقرير الوحدات',
      :tooltip => 'إنشاء كشف وتقرير شامل بجميع الوحدات ومقاساتها وخاماتها مع إمكانية الطباعة والتصدير',
      :group   => 'reports',
      :rgb     => [37, 99, 235],
      :bg_grad => 'linear-gradient(135deg, #3b82f6 0%, #1e40af 100%)',
      :symbol  => :report,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polygon points="6.5,2.8 14,2.8 18.5,7.3 18.5,21.2 6.5,21.2" fill="#ffffff" fill-opacity="0.12" stroke="#ffffff" stroke-width="1.9"/><polyline points="14,2.8 14,7.3 18.5,7.3" fill="none" stroke="#ffffff" stroke-width="1.6"/><polyline points="9,10.2 12.6,10.2" fill="none" stroke="#ffffff" stroke-width="1.5"/><polyline points="9.6,19 9.6,15.9" fill="none" stroke="#fde047" stroke-width="2.1"/><polyline points="12.5,19 12.5,13.6" fill="none" stroke="#fde047" stroke-width="2.1"/><polyline points="15.4,19 15.4,12" fill="none" stroke="#fde047" stroke-width="2.1"/></svg>'
    },
    {
      :id      => 'pricing_launcher',
      :title   => 'لوحة التسعير وعرض السعر',
      :short   => 'لوحة التسعير',
      :tooltip => 'حساب التكلفة وألواح الخشب والأمتار وإصدار عرض سعر تفصيلي للعميل',
      :group   => 'reports',
      :rgb     => [22, 163, 74],
      :bg_grad => 'linear-gradient(135deg, #22c55e 0%, #166534 100%)',
      :symbol  => :pricing,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.4" fill="#fde047" fill-opacity="0.22" stroke="#ffffff" stroke-width="1.8"/><text x="12" y="12.6" fill="#fde047" stroke="none" font-size="14.5" font-weight="800" font-family="Tahoma,Arial,sans-serif" text-anchor="middle" dominant-baseline="central">$</text></svg>'
    }
  ].freeze

  # ============================================================================
  #  إعدادات التفضيلات (Bar Mode: 'slider' | 'toolbar' | 'both')
  # ============================================================================
  def self.saved_bar_mode
    val = Sketchup.read_default(PREF_NS, 'bar_mode', 'slider').to_s.strip.downcase
    %w[slider toolbar both].include?(val) ? val : 'slider'
  rescue
    'slider'
  end

  def self.save_bar_mode(mode)
    m = mode.to_s.strip.downcase
    m = 'slider' unless %w[slider toolbar both].include?(m)
    Sketchup.write_default(PREF_NS, 'bar_mode', m) rescue nil
    m
  end

  def self.saved_bar_visible?
    val = Sketchup.read_default(PREF_NS, 'bar_visible', '1').to_s.strip
    !(val == '0' || val == 'false')
  rescue
    true
  end

  def self.save_bar_visible(visible)
    Sketchup.write_default(PREF_NS, 'bar_visible', visible ? '1' : '0') rescue nil
  end

  def self.auto_open_options_enabled?
    val = Sketchup.read_default(PREF_NS, 'auto_open_options', '1').to_s.strip
    !(val == '0' || val == 'false')
  rescue
    true
  end

  def self.set_auto_open_options_enabled(enabled)
    flag = (enabled == true || enabled.to_s == '1' || enabled.to_s.strip.downcase == 'true')
    Sketchup.write_default(PREF_NS, 'auto_open_options', flag ? '1' : '0') rescue nil
    flag
  end

  # ============================================================================
  #  توليد أيقونات PNG ملونة ومميزة للـ SketchUp Toolbar
  # ============================================================================
  def self.toolbar_icons_dir
    base = defined?(OFFLINE_DIR) ? OFFLINE_DIR : File.join(Dir.tmpdir, 'dola_offline_cache')
    dir = File.join(base, 'toolbar_icons_v4')
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    dir
  rescue
    Dir.tmpdir
  end

  def self.write_rgba_png(path, width, height, rgba_bytes)
    return false unless defined?(Zlib)
    raw = String.new("", encoding: Encoding::ASCII_8BIT)
    stride = width * 4
    (0...height).each do |y|
      raw << "\x00".b
      raw << rgba_bytes.byteslice(y * stride, stride)
    end
    compressed = Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)

    chunk = lambda do |type, data|
      t = type.b
      d = data.b
      [d.bytesize].pack('N') + t + d + [Zlib.crc32(t + d)].pack('N')
    end

    ihdr = [width, height, 8, 6, 0, 0, 0].pack('NNCCCCC')
    png = "\x89PNG\r\n\x1a\n".b + chunk.call('IHDR', ihdr) + chunk.call('IDAT', compressed) + chunk.call('IEND', '')
    File.binwrite(path, png)
    true
  rescue
    false
  end

  # أيقونات PNG مدمجة (16/24) لشريط أدوات سكتش أب — مرسومة بنفس تصميم أيقونات السلايدر
  DOLA_EMBEDDED_ICONS = {
    'gear' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC9UlEQVR42m2TzWsdZRSHn/edd+bOndzEpDe5xIb6EbTWK4ptFLPViht14daA0ILYZTf+B+K6Llx01UWJdFNERAiCUqSUiqSxloq9aKQFTdrEprmf78y8c46LaM3Cszm75/c7cB6DqsUYeeMnXdgRlspSZqQCqxj2jRjURhDHdmvKsvz1C2YVVWsAFlf1g3sjznSHpCJgDFhAAN1PUbAWJjJ8q87pqwvmrDl+U4+u/+Gvbf7liTWEyKjJxTIMNRrOE1tlfxlRtDTOzTZT5ufSY26nF07sDgLW90K/wklpODCW81rzN77ZOkzfR2DkIcA4SxYRdgfO7fTCCRfKMI0faT4YmffaEyzOTvISH7Mw8TlXeidZrU6RRZ68stRdxKU/h3z28wNTS1MNpZt2iFRa5obS0xvGSFHHRzUgw5cJkeTseIuzQqIlvcEISo+WuUHGKoeoCbkn0ZKLP97l4pUNyF7lyak2v28fhKrDscfW6XSb9LfGYUzJsoSQexA1DgQbcob9Ae+0W7wy16BfCIU8TmQMz9UvsXToE27vHmH5/kesbg754uYmjXoKCA6p0MKj+YiGDTw7GdMtLDUbiKOIAxIBhtQZ2pMxt+4GNB+hhQepcKpCyD2xDZz/rsP5lQ7TcwPyytLbyCCJefGJd+k8mGJ47zI0LLVGjZB7VAWHoLbMybtd3j56mNfnu7x/8Cy5pHy6/iHeNOkVz3PcVDQzw/d37vPl2m3itA6COhWJKLxqMWLMCPOTlrorcGppN2PEZUSmIojDGMuNO3snU3hVkcglaW1bJBiD6IXLa1z41rL49FuMQsT19RtgrwHmv6eOHZEzKhJMkta2bas9fm5qdoaq13VOihAneXW1k1XX12tVUvNVHEuVxNU/Wyoneah6XTc1O0OrPX7OrbTM2uIP4ZSa6MzOr7dSKUrq9b2wSs1DCyyAKnES03rqGX/o5YXTKy2zZv7V+c0tXdj4ZXep7HdnROz/62yFuDGx9eiRR5a/mtnT+W+8loz3aA6pkQAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAE/0lEQVR42pWVTYxWVxnHf8855/2Yd2Y6zOgM05kyQM20KCVUYjWNUcoCIyE26QLddIXRRWtiqnTVhWxqQiLFVRM3jTvb0FhdVBNBkZKKTZS0tg1Q6wyFDlA+hvl85733nPM8Li4v0ITS9knu6ub+zz3/5/8h3BgTENv1kfUtL7OlSAxTAIE7TwIa0Ahc7u3lxMHVstTFAhDMBAAR2/qu7Vku9YmlZVuvzvN5xmmmr1eme+vu+aMb5VddXPmFmdsL9s03eemasOv8BwWpU2CgYJ8RXhBwodlgbG2DQePg6w/yg70gAvDtd+xnlyL7p9++XNZrLojgbnwohkdRBDXHnQ41Q8uoaf2m4fpIjZ+/9oA8J4+etP6ZuXTqv+eWRrXoICLOCUjFH4V62qkH7yL9oaB6cxtwQA3MTF2jyeSavovjq8KG0G6wZWkljcWFOQs1LxjMRwNTsDp3txZ5fPwQp5cmOHplEujcHt1Bf80hgosLHVtaaY61V4ctQTMjWcFSaUiQmI0d4z0MNT3LRYe9a/ax+YvvkooWz0zt4XT5EA0X0Yp3skGPF2YL5chMm5oXLCXLimhmJDghY4rFCGJYNg48PM79g03gPZg5SWdllKZcYN83TkJrx20pOn2tZPOL82CCxQSmOCEHEwRVLJWYA8nKzj+e4e7eQM7GLye/yiPjb7LQHuInhzfw3soZenxJVI+XavkYXGgnJEXMHJZKUMUEqWykGVJEHTiDc9ci01cNJfDYld08MnKaqcUR/jM3isgVrGxAKCDVIWTEKUGEmhPUgBQrzK5PTTMWS3CgapQxX19eh7mO8Icr94OPEGax3OKpTa/x5FeO8MZHk/zw+KN0OhCd4YPHOcFiid04wEOXIoKgSfntzvu47wstVqISHDhRzCDj8WmGb/lXwDu+tO4IXx7dzHLze0zNLvCjV9/HhZsU4btJoxlihOCwpKhmhhoOrTtq3sB8pXEESR6iqzxqwlDT02wI7+eEpVjpNd5CkQdMFYslGhyiyu6X3wInYAZlvcqtWqwwc4OnHtzOk5uP88bMA/z42F0sx2NgSj041Nx1ihR/k6JcqSg5BPCm5ELB1fnOuv9RZM/RD8cxK4CSA8c3cuBfk5Bq4AtwhvMOUVf5M5XVDT5GUYpIDuSUWTvYw1Czn+/fe5inv/53yI5n/rGDQzMPU69HALK2cGIYYCZcWOxwfq6ND/7jKhIwU8VSxFLAUuLV3dvZMNIPs7+hmKvhSDz73XM82//0JwbdqUsLbNr3J4xQYWnlkKCCr5ZcQvZYzPz05X/SV+tl5z2j7P7aWcjCr/82xF/PH6NeT+RuhVDJulnzzLbL62mgFZZmVPDBt7jkBSxH0RgQjL+8dQYSvNLcyOGpPork+f3JNZBOdYvqNmEnhGYNjYrlKF7At7gUxgY5cXH18PlaT2tUi46JE1cPIAGyRX7377UA1JoFruHuENeGpoiqaa2nRd/q4Qtjg5xwL4gsrpoY2D+xdZvLs1eTlaVqSuSUICcajTaNRhvLmZziJz6aElaWmmevpomt29yqiYH9L4gs3qzMt3np4qnpXWcP/Zm0MA9m+rlKWcSFuwaY2L6D0Q3rD76+qVuZt5T+tjO2Z/7Da0/MT51dn6N2G/XTxwxfcwzcOzE9cM/g80fW3VL63NCDCWC7zPqWV9iSCoYpP+Pf1yE0uNzbw4mDIksVoBgY/wd3pcunL4l69wAAAABJRU5ErkJggg==' },
    'grain_z' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC8UlEQVR42lWTzWtcZRTGf+fe985MPsbEZFJrKukigUCL0LQrrYEqItqACIKbSqEL7UrsfxD8A4QuihDEFNHuhIigK1sEKWgwMX6UYpkoTbGkmUnGzDhz733v+77HxYTWPrsD5/ccODyP6CKRfEDQ7xdO4ffOhcJO4AFB+L8UJYYoKTWIx67J/NdrukgkAHrj9EW6zcuk7QohPILkIfxIUQQDT2QM1S7JSzeXRFdfncvvbq7nuw8oQuQQEZG4z2nfTCQ6mD2oahIFUx5/ivLR6ZPGtVoXQrdNJxMXm9ho8ISs2QdLg33Q9vrHK6NIFJNZdUm3bVyrdcF4W9R6qdPCx2KzNsRlRubeZ3DmLFKaODBo0Kt/w/7GJ+C7SDIsvdTpsC1qRhVf+Fi6+zsMHX2eydc/xqX/0Lq1QmWkC0C2P8TI8bcYPvEO9796l97WD1TKNVHFRwEj6b9tSs/MM3X+Oo21T6kvL2B3VhidvM3o5G3szgr15QUaa58xdf468cQcabdDIBKjGsgd2DRHUCSukBZCOXPowfuzzJEWgpgyqJKmOepAFYz3HscQe/VVNq68yMybH3F8doHWne9obN0DYHD6LEdeO4Ni2Lhyhva93xk/NIb3HhOALC9wZphG/Ud2P3yOQ3Nv8+TMPPH4C/0sNO/w540ldn7+nOAsUWmIPHcEwBBE8wKyrCBOhrG24MEvy9z/aRlTKYGCyy1xArkt93eygrwcQxA1Pmic26B5AbE6sk7BsVdO0Gn2QJSkbCgyT7U2yOoXv1KpCt5BboP6oHFUGkiaXkVSG7RwkNkAkeKcI4QAETjnIFIyGygcpDaoV5HSQNI01dnDV8dubb/3190tY8vqnBepr29jc4eIHERY2d3uYr0Quk5d7szYsaepzh6+KgDu29MXf1vfury5uVdxRcAXAXm8i6hCnESYJGJ6eix79uTUJfPyzSV5WOf6G6c6f/x9rtMpJgwQ9PE6R4I6oFpNGtXZI9dk5ss1XST6D8U7lmzCoA7aAAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFZElEQVR42p2WXYhdVxXHf2uffc/9mDsznUx6M1/NdExNa60NRPDBBK1JFSRgaUIaKvigBZEgCGkQX8SCb2ILfcmDYBUakTYJUmtQ2qZqSfogOE3EGJM6Tq7tzXxlvu7cj7lnn72XD+feTgMi1gWbs86B/V97rXXW/7+FrimIgOpfj5bpdPbi3d0kHiL+u3kgjiDKLZHPT8tDZxo9LABRkC666qVHTwbXPK6NjanIBED430zxwSDl/lmT6zsl+974sSqCgKj+wMAzyh8feQlWjibVOTqbDoTARzHF5As54slRYNsZPv+HY/CMCIBePHiCZPHZ5auziYlzFozh/7IQQuLS4U9OxcSVp2X/hedEr32lP63O/7313szIZhIQuBNcTLZ6nco+dl9Dtu5IhFCIDaV7ds3byZEHLO1kr283x9briUY5K6h+CFhQ10LTNhq24vR8sUUkVwLVrUAiZr2eaL7dHLPtZK/FUZEQcF41GARVxFhC0kLTDvH2T1CaPEC8Yw+5oV0AuNUZkoUrtKtv0rl9DbF5TK6EhhRE8F5VQhAcFYs1Pii4VFFREItvrhAP7aLy6I/ou//xDHTtJsn6IgD5nQcpP/wUAM3rv2Lpje+yuTpDVNwG6klTJShgjbegEoLinIIR0uYyAw8+xviRX+A7G8y/dpJW9SK+WWNgZxGA+r/aRH3jlCb3M/zZk+z85mVqZ5+kfu1VbHkI55QQFFCxAD6ASwXVNgMPHWPiyItszLzOrfPfwXfqSFRifN8Ug/fdBUDhH2vULr1He/lF1q6+wtih55l44hzVl5+kfv03eLX4bksMQFBIXIo3Re45/HPS1jKzZ58iSTbRwg6kUKQ8UiK0OoRWh/JICSkU0cIOkmST2bPfwLdXGT/0PKkny0B7ASIIXklDRKfV4MbpY9jSMJOHf0qqMe21Gs21Buu1Bqacx5TzrNcaNNcatNdqpBozefgFouIQM2e/hXMB5zNMIshKpOCcxxSLLLzza7w/wgNf+yWf+vbbLPzpZyz95RVm3qqxWs2avFJ12P5x7n74MXZ85uuYuMzVFx5n+ep54r5BXHsT383AZvOnJKkizkNhgPnLr1Kv7WHq0A8Z+9wJJg58D9e4TXvlFgA7t42RK28npAmLV84xe/77tJZmsKUBEpeSpL0mfxAA0lSJUlB1SNzPxu0q7/zkq5S2jzK0+yB3fWwfhcEKIKxVL7H2z7dZvXGB1u05orwlivtxiUPEZL9p6GUQZSVKUsV4zQY5TcHESLFAfWmB1dppzFun8S7bFOUgeIhiQ65UxmvAJykIiGTV8Eq3B5FoCIpLlShVtEsVEsBtdnjwwG7ERFz57bvs+fLHAT7wNXj+9uYMuYLd2ifZ0IagEIlaNETeZyVKPxxAIEkClfuGSdqOViNhcLSPfF+OdjPz42KOy797F7F37ktTxXtAQ2Qp2kU1hsQjke9ylnRP4pW04+m0HC6FTssR2QjnodN0mMjgvGJ8xndoRoKJR9QYKNpFS39leriycKuvGI9sJl7FiFHNFCEbGMXmLS4Fm7cEVZIEbMHSo5jIZyURAU1D6CvGDFcG5uivTGeC8+cvnpi/Un325XM3kv6BnDWRGAG8VwYrJUSElVsNto2VQWFlLvNVlfXFFlEkKBC8ho26S584sjse2TP5tHz69ee2JPPiIy+9f33u6IXf36S+kaCaSaZPs9RtDGmSlc/mtvzI9mQAM9Afc/AL9zJx/+gZ9ncl8w7Rn/7SyfW59ePv31ydUucx0u0aoKrIf/DRjHckFzFx79Ds4OjgKdn72pbo9wRQuw/V42Xm5vfSTj7ataUYLzE6Mi1yqkHvCgT8G70M+xQCm690AAAAAElFTkSuQmCC' },
    'grain_flip' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC2UlEQVR42l2TzWtdZRCHn3nfc04+blKD3NRAtVWxpQuptgUR3EgVRNEiSJGQhWYhWVoQVNxc8h90G1zHjQgupMsoBaGbFi0uBKGaWtOEJHCTe5N73q8ZF7cLcVazmGeY+cEj1us5WV1VW3//MqP+kqY07wqoIPynnGHqwdX1LlNz67L0/R3r9ZwA2NdXVjjcu8HRYBJVkMes2WPaAQJaxn1ntuVE97p8srEm9s3Vi3Hz/t24u0NSl/FOLBUQQSoBEywegRkyOQOqVqNVc/IpmjPPX3K531+2wSHDKDnhqjAq3p6c8jrb+Nji4/HAV69+5Js3PvVhOPAJXw2TZBsckvv9ZVdi7I5CsWRIO8pop2Zu6Rxzi2fJUzWjwyH+hddoXlkktIGQIarJKBQrMXadmZRUTNqoJIPu4ln8TI1/YoLu0jmiCulwHz0+IGQjJiUmIxUTMymVgoRsxKz4yrOz8ZD510/Rbh0x+GNINFAcJp6QjTobWoyQjQ6IM1VSVmI2QlQe/fSINEyEQWL7xy1icRQT1CCpI2Ql5DFjqlQKxGTEZDhvlMZjIihCahzH+4UcI1oyg73EdKOojucVcKYQshLTeHMIBTOjFCUmWLj6Mf7ESfxsl4X3lokqhKCEbJhCZYjFPP7JYaRsFIVSjNFx4ulrX9A5dR6AZz78ioe3vhtfkA1DzKmZD0ltHKTRJsVPOHynYTRquf35W7T7W6Rhn9tfvk07GpFUCKmYmvmqaZo9xUmb1GogK2z+vEM6ztjkBAfb/3DrszdxVcPB3/epOzOkkGx2upamafbEbn5w8d7NX+/e++UvfF1lEZHcFhCoJjyIo8QRmOEnp7FSrKRcXXj5WS6889IlAchrV1Z+/+3BjQebe5MpF9zYMUzHLokTQNBSqGvP6TPd9vyLp69XKxtrYj2crKL2w7XLR39uLw2OwrxT4H86Y5g6mO1M7HaeW1iXd7+9Yz3cv7J/06/FPlWaAAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAElElEQVR42pWWS2icVRTHf+feb5Jvkkw6STWNQdQYKhVclSIVqktFEVTwheKD7uzSCoIuFFzowgq66LI+dlUQF6KouBF84KMLFXwbsbWxiabTJNPMfPfec1zcL482UvTAZT5m5v7/53/P/9zzCXUYiIDZ6wdGcH/uJqaLqRJ4LhwJGPBQ+AV08pjcfXhlDQtADKRGN3vtlseozh5IKyvTHuX/RMLhR0ZmGRg6LA++87wZgoCYPeXgaePIjUcJnbvC73P0+wG4EIMBcv6zGxxs0LjsEmi032D/+/fA0yIA9urNj3L2r0Onv/u1ksZAISJuHcsJmNWC6xABq/nF5d8BM1MLVRy7+soBhi46KA+9+4LYW/tb8eRP3/dmf5nsBSWD2zqQ9RMIyICvgQTThPhGBk0BcX5diZlp2XCU0zN/FlM7dxVUi7u1251a6lbmG4WghmGIE3Q1MnjlKKjR/20ZV3pMDWLF+COvA7D40u1IUdaHlRNc6lY20O1OUS3uLlCZEFNCNFOHYAYOdDlQzmxj7P6rsKAsvPI9/T+6+LLAVHDbr8ANjxFdE2IEqe0mkKKZmAoqEw5vSRVisrzUCL2EjJWM3zENyZDCMX7nDLQGqPpKiBFdPYOFVWJMxLRpf71UAW/JkUzUjJCMlIwQleSEyf27KMZLtFJSN9CYaLLjvp01AJh4wG0BTyljqRkkkyJXP/9J1DAFi8rSN4uE033GrttBWgn8/dEcrvTEZKC2bqyolgHEAEMkY9XGoqCApJmVZFi988Sbs+Bg/PpJKIS5948jhc+FThueDWkrQUhGUoMCCgC1/KWsEZBtaZLdZwap4fGNrEDjRoZRs6LzCXRdAaCaz89tIshZ1R1hEIOiIojzqDmMTJIst43puUekNcO6gpj0PIKN28BgPYG4vIhWab0XV5c7EAJ+pI1I3hKTblLgs4IqGlJcgECBXp/ph54jds8Qqx6+6jF120GaE5fz85HHQQRxUMVagd+sQA2vWwksK881EmP7tbcyfOku4tklXGOQmYefpeos8MPLT+ZrwzxRN2rgcGJqtqVR1pYZaO39qMYXT9xCb+E4xdAorjFI1Znn00f30T/bJZkjJs01MAMn5kjik+YMtxAo+IajaHqiKepLlv6Y5Ytn7kVjAOCrZx+gM/sjVjQJMRHrRksKJPEFZTlvzhMTEhOZGUEE0mri9G/L2e/BUAIytI35rz/h48dvxjUGOPX5BxTD26hCAAQnEBNizkNZzheMNo+1t4+eHCobk72QTJw422TRj1/8lrXpowqkgDRbzH35IRgUwy1CDS5iRFUdKhu0t4/OMdo85mTfkeXWZPvQ3j3TrrO0GqugqpbBTIQYjRgNE0EV1ISUFGm2kKEWKSlqghpUQbWztBr37pl2rcn2Idl3ZHljZL5y09FTv5y866PPZlnq9vPlft6Q/LeQjQc3OjzIDXun2TEz9QYPv5dH5jlD/+itjy3Pdw7MnehMW0w4+W8DXw2k8FxyaXu2NdE+LPe8vTH017Kw+sO+PTDCqc5uer2LSf/xlcIDZbnAjvYxuebwytrUNuAfVOIsK+R0iEoAAAAASUVORK5CYII=' },
    'rotate' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADJElEQVR42lXTTWxUVRiH8eece+fOTDsz7TRtIDS1Jogi9SOUBbjAVEUTEzVGJTGiiV0YXOLCxI8Y4oqdki5M2KKwYcHGlSWGBvlIkRoqNoAltqUhxU477Z3p/TrnntdFa6Lv/n1W/586LqK/VsodzmRfM+eINa7P5RqcU/znRCPKg6Cgl+seZ84F6sZxEa0AXg7laMNwMkwo2Rw8DR6QAyKbAQUIoDXUSiS9BY6N19Qp9bbI3tn72dTSaorKra14SoXW0cqFLl+hldr83KqIIM7z/e09RR4bCIb9lVU7GkaCbLRth+/5P+zqpqAU86nji79CmsbhbzW0UgggSWLDUuCvrNpR32R5r92IxTdGPYwzflsr8/FAFWsT1jdiPMChUAihFQpaESiU3YjFdJV7tUZyZYwK2wn7y5oP+zu51sx4Y3KJdmSIY8gTQ6OdM/ZED690FWi2Y7QxSiO5ltwp0owoSvh8Zzen51q8PjFN3S6zzYU8ru9RsS368wU6JWG0v0YWJ0iaIblTGhFMnNKdW4ZqRc7Ph3zVd57D1UnerFzjRP9Z6nmT97uuMPngHjsrHfTkFhOnIILGOVyaodKElgk4VPmD4coiT5cXudJ4hEZS4/nO23z75yEW2lWKGGyS4dIMnEOLEzxjWF2PmFtv0tP5JJ/9/hy/NAYJ8oQ7YS+XlwdohxEj27qZWW2zth7hGYM4wUdEXJLiG8uJq3f56Z39fHfzAGO/LkMZLs4fAJMysqvER0M7eOncdQrW4JIURMSX3HkmTqSCY2L2IZ9emObnt/Zw+tYiF+YaaCW8MDjIB08N8Mn4LSZml6gXfUyciOTO8/1y0NBOVBJFUg8Cxi7f4fpCgy8P7uabF4cAmPl7nVe/v8TV+yvUO4pkUSQd1aryy0FDvSuyd+rH6am5izfxA8/6vlat1CDWUSoVAEgSg/I11WIBa53YLPcfHXmW4deeGd7CZI/OX7p9sjEzX3LGoLVGAbnbRODpzQk759CFAr17BpPBg7uPjdf8UwoRjVLuPZF9D5Y2jqRrrT5E/wvwf6JRjmJ3dXnH9s4zZ5W6gYj+BxHmsVEQE6K+AAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFhElEQVR42pWWW2xcVxWGv7XPmTPjy0w8TuzajtNgO6RASdMaISJMixAqEreWVlQUHkCgCkREK7WJQOKBpA9IgJpIQShAVVDVh6A2CNpyEzy0okgooVGai4CExo6TtLZlO57xZTxnzr4sHmZMnD4kYklHZ+vss/9/r73WXv8S1kxVENHdqp3zMOqgxzeAiBubhygPMcxtgpOHRVbWsAAEVQFARD+T6d66ZffKqh8K8c2QrzfjPJ3t0cW2HId/n8hTa7iyT9XsB/1kneerOR6aumixaQMDQQSCgq45eQMCAZMr5BkYytFlOfqnNr6wH0QA7kv1iVnhwPjpSpbkJDYiZskrqpA3EIsQyc29UNWQWXUjO8tJr7Ln5YIclK+pFicq7tyFt9K+kKYYEZMG5cGNefJGOLZsWXSBqlNicyMWRRBUNZhCgW2DhZnhcvyeeBlGa6thIKsuai4XSVAwCo/1beD2jhyrXqkH5afTq/zg0jLdOcHrelgwrXcARDBZdVFr3cnAcplRo9DrETRzGqzDOEfasDx2boHphqfNCBtzhv8spUTOEaxDW0+wDqyjkVm0NcY6NHPqERR6YwWPD80fRMlUKYpw8N1l+vPNTHr8X/McubJIXz7CZ9cFFqtKTxKxYB0gGAG1HnxAwRsFIQQ0yzDOU13N+NaWIjtLCf9ebvD05AJPT8xzi1FCliEuA2sRZ6k3MoYT4cTYIN8cLFJdbWCcR7MMQkBBYgBtedAw0GuEr2/t4nQ15WN/HWfJt9Ee5fBk1HyCAEYCsQQiVSYXMyZrjkeHyjxzYZ40y5pH6EPzfgAQAuIctXrGaDGhO4l44fI8lZWIg1t+y1Obf8VSGvH9/l/z83f9jO/2/o68r/Poplf4aP5v/HJige4kYrSYUKtniHMQ1hGoD2AdNrMMtcUo8MqU58Od5/ls6Q3uKFyh0VAeKL9BrJ5Xrw4T2YyyWWJzvMLpuSUUGG6LsZltBvqdHqi1qLXgPQC3RBX2bv4LL8zuJBJHn1ng8fP3cabaz4Hh32Cc5cDFe3j2rQ/gXXONen8NJ7yTILNEzjNRqSHARzZGLKwm3Fs+z13FK3yofZwQYCrdwGB+kQ5doZImVFcDHyznEWC8UiNyHs2uETSDHAIus7QXhNenK1xNLR/fMsTokYd5X7nCztLb/HlmmG9sPc7W9nk+f+JhLi0X6YhrZCHwxZEerqaWE9MV2lVxmUXXE+ADwVoKSczMcspPTl1m364Rvj1a4kd/r/Dm4m2Uk5QfX9iFV0NHZMmbOrNXG+zZNcKdPUWePDbOTLVGT0cBay20YhDnQDV4NHO4nKVkhEPHx3lwpJcf3v1e2kzEodfHma144qhGDqh5xRQSvje2jSfHtnN6dolDx8cpGWnuPnNo8ORAYyBq3mRLsBGRQt15Hjh6jF98+i72j23nK+8f5LkzV/jn3BIAt/eU+PIdWxja0M6rk3M88odT1NMGhTgiBN9KlgAQxQZmjShYJ1iHC0pB4O2FFT7x3Gt8acetfGdsO/vuvu262nlubomvvniCI2cvY0QoxAafBYwRsE6MKAZm4zY4Wervmsp1tPf5RqoiYpwqSVMqePYfb3L0zCTbujvZ2tUBwKVqjQsLK9RSS6ktAVVc5hERvGrIdbRT6u+aboOTTcFRfeLyqfkDZ595MSt0dcQmjszaTiMRXFBS53FrmWEMhTgiNoLXa7U7OB/Sas3teORzya13btrzssjB/0nmpzKenzo789DES6/RqC6BEloqhYggAoamV4Gm2q3NtUqryXeVGL7/HgZ29B39Y7ImmetE/37VvYtTy7sr41NDznJt8c2lkjgH5ZGBixsGiodfknWi3wKn9UF3q3ZWW23L/9NVxDDXtda2QLNtUeW/sS8LEX/BgdUAAAAASUVORK5CYII=' },
    'flip' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC/klEQVR42k2TPW8dVRCGnzm7e+/eL4Md28ROgiPbKNhYkRIXuEuDRBQJkCgoSBWa0CC5okKKkPgB6RBNUqUB8QMgBRUggcCSsQCRWI5CHDu6N8Yfe+/unnP2DMW1EW/1FjPvzGj0iN5SI59KePilLld9rlsXJioF1AgSgAAagwSNBGqJ6UYt7s2/J7/oLTUCsHFHbxZH3M4HpCEAgAiEauhNBKrH3kCjSZF2WF36QL6Qra/00pNH7tde1xLUeRFk2BzT7HQRU9E/OI2JHKqCKmokiccnapw9n1w2+3v+RpZB7jLvg49dcJH1ZdQfJNHk7PfR/OWvo6xfi2ywkatc5IOPc5f5LIP9PX/DOF+N52WhrvJifUlpLS443lhNSEZmcHbAlXc/oywC1lusL3GVl7ws1Plq3KhSOe+kdBZXObKjkumlhKlXDBILtoyZWfyBU2fWyfoRriopncV5J6pUJoRKhsmW0lm8WhautFGFerNLZ2wbQszC8n0K6ziptd4SQiUGwDqLqyxHhwXTi3VGJmo836442J/i8eYsg6zDmfN/MfbSA7K+YH2JdXb4lRCU0g+T86Jg+eopHm0c0NuB8emnzC2s0Xs2ycE/o1x8/TuyPsMzvCMExQQC/nj62LkaZ19t8/O3u9Sbnu6zUbY2Z0jqOb+vL3BhaZ3myC6DfsD5kkDABEVd5ehnOStvneb5Ts7RYU7aiqmnOe2RfeLEsrszinUxl1Z+5DATfLAERY1qFeVlqVGqTM+1aLRj3v94kXpLGRz2MHFFHDuuvnOferPgwmt/IlFGXjrVUEVxWkt6QYMUrtDPP/mJE3mnVPZFRN6m0SpI05KghjJPsdVAg7YkrSe9eGm2dfe3B52Ptrb/jvOnpTcY0WMWxBhQ2NuvE0IDEUC8hlDEU5MdlmZbd+P2NVnbuOM/FIlvP3z8JLXOIyIo/EeQyHArVaWWNJh/+VyxcnFutX1N1uQE5/43uvzHZn79oH80ERBUEf4nEdSgvNDqdBfmGvdabw5x/hfJFc33v9b4uQAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFNklEQVR42pWWz29cVxXHP/fe92b87BnbmcbxjyZx3ITaCQ5KHJmGJgVFRaJCYkFRhRCwZFMWSNC/gRVh2Q1LqFDVBSA2IEUQVekPtSWNUlVJ2iRN65DYE8f1eMYz89699xwWM47dZFF6pKO7eff7Pfd7ztH3GR6EGjC68m+txAYLMTBWBP6vKCXgEu65ES6OnzGtLSwAo6hBwRijN/+sL/kuLzY3ZcYZy1eJqEJ1yH6SDvDyEz8xv1NVgwGjqhbQa3/kVVPwwqdLgU6egyIPg5heUaiaRxkMNiuXmd6XoCVem/05PwaMAfj4Ff11bHP2gyvrRZqaBPvF8rfgRBwA1sYe0cMkouK9hqOHR0tukN987afm9+beX7V6eyVcXbqVT+S+izGPamOskLeHOXr6FQaydd4990vK2Qaq9hEWVZVyOsC+A+XlvePJXOKFhU5bpzY2m5qk1jwqDCARH5TyYJ3axE1CLLAhoqqYhxkMdmOzqZ12acoLC4lE9qhafPBqrDPa/14Ba6HbEhZ/VGV4skT7htBcH+PEs38gyzY4/7dfUco2UTEPZDQGfIiqao1E9ljriCIRHyM+hv4ZiRLIi0BaUea+U2H3tHLro5NcevP7DI2sMHP8HEOjn5F3LVH8jru9UyRiHdFGwYgKIXpCjIQYCDEQNdJuefYfGyAdcDTXLPtn3+HwiX/QblUga3Nw/nU6XUeUnXcjIXpEhSgY6xyIKCGELxB4H8BFDj9T7TcP0lKb6q46ECGkHDr6FunAffICgvhtghAQUZwD258ufB+4V31gc7Ngaq7MnpkBNu7lpGWlfneCG1fmsUmOb9QYqdU5MPsf2u2k/4p+cTEg2psWu7WFQUIvYyBIpCg8x5+rsV4vWLraopQpa6s16ncncUlO4/4YqyuTfOOb54nk+BC3MSQQtwgcoCL46PEhEDTQ2cyp7U05cLTK5fOr+CIQgmVm9hILp84RggWE61eOMHHwY8Yfv06743Y026MiOMDiIIpQhC3mSLtdcOy7u5GoXHtvjaRskB37IQJJ6rmzNIlvD3L85AXyvN+HEChCIIrAzh6EGIgxkHc92Yjl2JndXL+0TrPRxThDmgofXp7lwr9OYZ3HGCHPLbeuHeLIwvtUR+t0u4bYl1l2SiSq+BiIRDYaHb5+qkZSsrzx9yXamwVF1xMDjNbuMzZxlxAMMVoKL3z4wZPYNDB/4j2aLUfUot9kxQGJs6hIbzyL3FIesjz9g8cpOpGZ+RGmjwwzPl0himXP5DKjtTU2WxXKgx1mDt0EA621UZ46/S5vnF8gL5LeHkjEWTQRcCI9iTpdmDxQobqrhAh8+/n9qEL0wvsXWoQ2uKRCfbnG/FOXeebZtzFWidERgmV4132W74wTY0BEEHBJVqJurBJiMKXUcefTBr/9xevEqIgoKBgLnZYwNHQS6wzN5iDvvD2LigEMxgm+SGh8XsW5Lr6IxlglK1FPskEuTjw2fCcbyCZy31VrjF2tt+jZ0fbkWAefr2co4Fzgv7dHdziCwRglSTzBq2QDGROPDd/NBrlozWnTnJ6qnD2zuGjXGo1QBC/WAU7BbqeogvVY29c3yXFJ0c8u1hXk3staoxHOLC7a6anKWXPaNB9Y5kd/4tWrN1Zf+Odbb9JoNVFV+SqebIyxI5Uq3/vW08wd3P3akz/rW+ZO01/5i760tNx68cbtlRnvHzjql4cqaQoH945/sm+i8vL4D3eY/rbrqgFUV7TCVRbygrFOAc59yd9EhKwE5RL3mOOiGTetHqBRUP4HzdlFtNaBDCIAAAAASUVORK5CYII=' },
    'snap' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC/0lEQVR42k2TTWhcZRiFn/e7984kk46p+RUVQ61FjKI2sViICgahbtwppOmqIOiyGzfZBDeuCy1IQcRNNeDSjaIQ/KMBSVqsRqJRQSSm+TOT6cz9+b7vfV0MBZ/F2R144HBk0cy9K6Jv2I/TLaoLPoRRcxFTlYQeEYc4TDQhS9PdQWrXP5WnVxfNnACcsx/e2tPu5bZ2+4wIIjigIMGAfgKKgBlCQtM1ihHXuPSFnLkmc/bz6Y3OX2t3OvuI1+AlkcSULhlPckCdyCqjDOCJ4sgsmmUuHR8Y5vGBR6bSnerwYrvq4Np5KF09fc+tMMUBtxiiYZ4T3GVd7ucZ9lljmAU9Q73IQzvrpDvZ4cXUBz8SOrlpGSQVZbZvi0eTA37zA7yabnGMwHaoM5X9w/FYkhY5aiqhk5uv+5FUTKNVXqyoiOI4rIEmgc/yYa7FCQzhoaTNa9mvHCrEoiIxxfq8iGlMURMtKjQvMVfDHR/HZYLYg3zdDgDMDzZx2TgujmFFRLVC++qgJilmWOGxwuMJ+KF3oDlM3P2SwfKn3oz2FIx/iG/v4//4hBq9DmakGhTNPVZ6QvRUQVDXpBEj/7ZaADSGIuqaVOGA0O2QJRmaezQoKWZoWSGFJ/ddlrc3mBmeYOHULKHyACycmsUBy9sb5N0ujayB9lU9A1EzKyt8t6DpEq7eXublkZPMjJ/ko+fnucf3d37n6u1lmprgfUGtv46oWaoxJpqXpkVFkiR0tOD1z9/nzSde4JWHJwH46u91PvjlOzqhpOZSYoxoXprGmLh6o3/PRRMpKjs6anF+YporM3OIGje2NrmxtYmocWVmjvMT0xwdtZCiMhdN6o3+PZmzndO3vlla+/PbFZIsDcdq/dJI6yiKWU9fBByObii5W+UWfUhPvHiWZ1+am0qXZOzmubDyNom7vLe+2VdWBTkVAvSihwEuExoDQ4xMPlZMnH3u0pKM3ZR7d5633ent1vqFsnU06sQwsf/VQUxMTagP3rf7wODk9Y9ldHXRzP0HVAaxhEdtGyEAAAAASUVORK5CYII=', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFfElEQVR42o2WT2xcVxXGf+e+92Y8nvGf2HHqulGC4xK5UqNWroK6oQgFoUKBCkTDLpWqCqFIgEizQAIpZdFVadllVxaJuiiVUpF2AxSBAhKKTBKjVM2fxpk2f2zHdZ2MPRPPe/fec1i8cVqpCLibJ129e777feec71wBQABFEOyg3WqscGcGdCyQAwn/fUVSqoD7eCvDZ4/KfW0MwWEYCGZSgog9becPd7Q42IntSc3c50JJ72v/AcZ5pZ40mnVXOfp72fPrzbhyxMy9CPYtzrxxG3lmcf0jfN7FQJPyElhJjtiDKPfLPQEigoDLqn3cP7CTLdib7/DYD14EEYDv2NyhFcIrV2+eLzJXSZ3gANpkZCgpSk7CIB4D1smoEgk4PI4GHgA11GsRdj2wp7KV9IWT8uir8pxdGPjQr16cv3NtPG7kOBGnQMDxBIss0c9tq1IR5YBdIkN5TaYpLGGL5Ixzl1PcT4oigJlpUqsyNbxj6QvZyHS6TjLTKe5O5KtrlmWZiCltKvzCzXHYzfIJQ5yycSZZ55+2lQnZ4DX+ylUaPCG3GKXFy7qXl/QRhilQcS5fXbNO/92J9Wxsxhm6TcUwH8x8QH0k8QVfZQGlwqh0WI0ZFZTvuyZPumtkRFa1zqh0UKo8yXUynxN9xHzAfDAVw9BtqSGRqFjhy8SZUhgsZX24pKyYD0M/p4ppnq1cwYBjxRQ7Kg2M93AYXUvABwwFEazwEBVDYpogYlGxImA41IzEYKC2AZIiFhjWNi91dnOycx8C3LGUlwcvI5mApCTqe+c3AQIWlQSRtEy/ltTEgSlqgsogxHlwfZjbTl9xlyEXAOhqijEM5KAtWuzAF0ZVPCYO8wFUAUgB7jEQhxiE2GFj6EeQnYFsAj4ZIXb/SKj0l71btKD2dRidAb9A7h8j3PgDJAkmeo9BDyCBqGhRlOgI5jdIZBiGny87d/lvUASMkgFFwKKH+jfLLl5pYvkGltUwDC0KiAokPQaqWBExF8vO9ZEidoGIGQxJhVB4EleaRCg8Q1LBLCICRexiPmKE8nwRsZ5EpeFsVlERoIiEvOBS6xZBSw/cN/YgO7MBrrdWuN5aYWc2wL6xB1GEoJT/5gUUsZSnV0X3JLLYS3ISiEBNhePzszw/+TiNtMJUfZQ/ffmHHGvOAnBgci9T9VGiKZ3oOT4/S02F6H1Pgc0c9CRCrUROAmpGnwjvr9zg2JXT/PihrxBNmWps5Vd7vvGpSZuSiOPYldO8v3KD4UqNGD3SK1O0lDMVzEoGHkszTI0gMEDKz0+fIMTAzx7e9zl7TsTxm/N/5pdnTjKQpITCl13ppIwVFcEsBZcQI5YHLA2YlhbsTcl9zqG/HOf1C//gwO7HeWhkAjPjwu1FXv/gNLOLl0nSKklWJRVXzgknWB4gRsAlzlFbdjjwUayI4CPdbpft1UHO7T/Ciad+wmR9hL3juzh59RxvN+f40vgudvZv4a2nfsq5/UfYXh2k2+2Cj/RiiMPhqC2nNcbODo5vW8jqtfHYzc0551xU1jpt3m2e52b7NkutVeYWmlxbXQZgbqHJUmuVv1+7RLOxzFqnjQuKWUBVNavXGBzftlhj7KwAfM8uHmpe/dcr7/32d0V1eDBNksQFUzrdDriELEnxPidJK2WCQ0GWVfExgEbqfXVSccQYNb+zFh5+bn9lctcjL5yQ6Vc/MzLn3li4fPGZ+bffJW+tgZqmzmEGipGIoFZWhhMhmuEQRCCoghNXHRpk6ttfY2L39Jvv8GhvZH5m6H/XPjjcWr15cLXZnIwxbLbh/14KSZIyMjnZHBp54Ohb8sVPh/6950JZPHbQrNFmfcazMRaJ/8ejBRISMmofNxg4e1SkDb0XgcG/ATegLedwtxi8AAAAAElFTkSuQmCC' },
    'door' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAACxElEQVR42lWTPYicVRSGn3O/+83PbnaTkF03RkKMa9BGJbMgEkijaWxTmsZokUpJp90QK8tgl0IRJK2IkEKQWAgiIbsoViaukmg0+zthx8nc7/6cYzGjsgfe8n3Py+E8Yv2+kytX1N79doW9ckFzWkQLIMK+McNVOF9vMV9dl4/Orlq/7wTA3r55ie3RVf4ed1AFJ2D77cgkA3FwoBtYmL0sH796TeydW6eb3+6tNZs7JNGMIRYSUldT00SWC9L24MRqc779xBHaJ0/0fB4MLureiKE2uaqcNzMOfXAOf/IwFjIISLdGN0cM+l9hTSaY5Xpv5PNgcNGVEhfGeWzJkoQmkA/XtM6eoLm/i3nBKuHx7fv43jH02CxhPCaRZJzHVkpc8KZWGssSSgQ1ak3knRHu6By7X/5IdbBL59Qi6cEu0QpRI1Yq2taWGbXiCyaxJBpNSFFME1YJ7kCbkjJSCtadwdw8yRKTRZ5YEgUTD0rUSNQIqqgmEGHji9t0XlzCUs3whxscff4goTGCRpxOPKD4okYoiaYkmDZQVdpPH6GaaQMeqQ+hJZM0ETUiZeIpajgFokbCVE1JGMbsS8dZ/+QmD258j1t4hWZ4nlQFQkmEaWOdxKs1mojTBqKJkjJh4xFPvXEG123x+OFftJZa/HsrV4xGE4iaL6pVKNEaTVgpiCY6i/Osf/YNvlsDwvjhgCdfXyFqJpSGSo1QohXVyrda3W3FZFyC+cqzt7XD5updlt96jRIiguA6NY/u/MHg3p8UDzEHm2vPSqvV3RZ7787p1e8+X1u7e4vKtyavXBTfbf3PkxklRBBBKrGcou+depmVM+d7ApDf/PrST+trV3/dWO/kkhARTHU/S85hGN7VPLO0HF5Y7l32n567Jv/h/P4vK8Pff74wHA8XHQZi+3E2MUWY685tzR1/7rp8+Oyq9fvuH2QWysGnPrN+AAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAEw0lEQVR42pWWX4hdVxnFf9/e5547N70zSaftkHQSxtZqg6ZUJlUEi6GiUBFEkOiTIohIi32wrfjY6oMvtfWhklDrqw8lCIJIVLTFUjUUHIh2TAMmsU2byZ/pNJmZ5N45e+9v+XDuTDKpBvvB4cD5862z1v7WXscYlcAMpCde67O6Nksqt1EaIHLjKhBr6MQL9Ltz9oM9q+u9AExgIAyTHvrz4z5ID2t19Y6owPupYo71+6dCr3PADn7qx0IGhukJBZ5EfOtPL7DK/ubtN1hrhoA5AMFu3Nm1rkHo1mPU0zPQ5xDP7/sqT2IGoIdeeZSl5umlf8031qkrAgHAMDRMaKPJ5jIzrFexcddxpSZP3vXRmsn6MTt4/zOm7x0bzwtvvH7l5Ontw9Jg1jZHIBedD9+KdSuwFnKjJJSdfPzCCG3jso/Fmi137jpb7ZjZXZEHs+XK4PZLw2XFTsdwQQhoZUj/63vZ+v0HbqjQys9fZfknL2MTY+AOZuHScFndK4PbqzyYrfA0ZcVJXuQezCQwUZqGzuw05cIq7z71EvXuKYihHYmmsHb0DDd/dx/1x3eSPBG8Ahcyo3iRFTc8TVVQFUckzyBDEqZAVsa9kJeuUN2znS2fu5t8bgWAzswkw1OLpHMrhG5FKpmgDBKGkTzjCKhKhTCXkzyBjwAskEcPSSLu3Mry4XkWn/8LGEw/9SXi9ASS4yYaz0TP4MLMSJ5wOQirRotPVsYURwxEUkYjABUnF6fJCRBeRFHB5UREVkEqGwyyMk475RVAkdN4Bo8bDJJnXIIAzcVVbvnKXib23QUY3ZlJ3jl8jC17a5xI8oS8Ru6YGY1nitYBYmRdIrseoBTCeJfTB//I4h/msWBYFGkpMP6hI/T3/JqLR75BsoC89csmiWJsGbhEUiGoXJXIMwJ8LXPT7AxTX5zFomEGaVnk8ydQ8yYySCqtb9SaM6m07K+VKHkmeN7MwEQZNEw+uAfqwLnf/R2AXd/cx5lffJLO/NeIN9ekdBnU35AobZIIWon0XgBJCFGazLsvH+PEgd8CsPW+O1GVEQ1S+8V4vgqg3ErUAkTWfRCvlUijMQWsjtzy6d2kywMAJu7ZxfLxt3AgjOQ0FSS/zgeRQIgqclLJJN98eClYHXnzV0fIOXPbg/cy9fmPsXzyLGdePEroVrj7e95LZSRRiKqQoquQldvZHzk5KaNoVP0xLh4/zaUfHWr3GsBipKwlqvEx8uU1kgqmvMEgK+OtL2JFt3deIZBULPqIpkWyOe/84xQ7v3Afn/39D//nZvf6c4dH61eQl3b9VEwhQLd3vmLb+Nzktqkzvbq3fVgaBQtBuWD9mvmf/YbF105S9br/PcWGDWf/egy2dGhyg2G4Z+/VPSa3TS2wbXyuDZxH/vbo2RNHnz706i+b8d5EFULcyMu0Orgmta6rYHRuGmtTT+BefGWwnPd/4sv19g/e+5g9u/eZq5H57VdeeOv08f0v/vMllocrSO2cWbxxNqv4erqFibFxPvORB9i56+5DPHd/G5mbQv+RuccvLS08/Pbiv+9QThj2fwW+EFZ1mL71A6e2Tu44YM/OXg399bTT6KSfqs/Cwix58P5+W6reBXbsmLPv2Crrv0DAfwAqpDLWuxQWyQAAAABJRU5ErkJggg==' },
    'led' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC00lEQVR42kWTz2tcVRhAz3ffffOSTH40MGn8EWLjwhZc2W4EEVy5EURw2VVXWQmB/hkurCupLrpq1m5st4K4iBB3YpMYQqqQTmZiMtOZee/ed+/3ucjCf+DAgXPEDCeCmn12D8b3tQ1rTkANQRQAzOEEUwNXVgNYfiry074ZTgDMPtmmPX9EO57DFEQABcprAAkQMANxUC43lDd3RH5+LGaffxBHh7/H0SvaXCRDBRNwxjxbCI4Zx6ACYgjOyiL7zsobdFbeu+tTHDywZsxk4pI49UudLZLVTKaHSPE3IDR5xOLcbTzzvI4nBHVptRr7ND944HObevU0WxsRgJlOqJzHV58yv74DGG3/W6Q9ZaYTYgRA6mm2+cXUc6bkNpo0daaeKYOLI8a6Se/WLs3VHs3Vb/Ru7TLWTQYXR9QzpakzbTQxJXs1k1ArufWs97aYTk5ZWn/ItP899dnXABSuYmn9ITbZp7v4Dv3hCaFWumbiTSE2SmwgNIlQG5qN0nW4sfQ2IKjr0GYj1Ib3idgYsTRMwatCG4XZNHAyOULzjFB8w50Pf2DWniPimOt9yeneNpfnF7iLGhGhqipUwZtBaJS2NsQ7RG7w6vg5a5t7dFe3yWnKaPiC/vFzOgur5JSwpIRGMQNvahaDERpDCkWcEoNjcnXA3MImOc+YXh0SosOcYqpYNmIwTM2cZitCbRaCXbvVmdTC2fEzfHWTqvsuL//cJUWIdSY2RghGqM00W+E7C+VQs0hTq/nSgSlmnn/PDjAUVLns/0VKnpwVxEitmmaRzkI59N3ljScrb/W/Oj0c+aJTJhEEhJyHHOx9B8DoYkBRdICEGZZj61fuvkl3eeOJAKT08faLX/959PKP4VzbKiIgCG2YAFBWixiGGZSlY/P9XnPno40d7395LP/v/MW96WX//utRXHPuOlcp/PXNOQGYKiytdAbd1fWnIj/um+H+A/OJxvTf5zU2AAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFDUlEQVR42pWWz2tc1xXHP+e+92YkyyOPJDySHNtBDoUsvPKmgUAJLa27SujCFPoPGLxsYwpNS0OTTWns7ATdJLtAySIkgbS0tDElm2QhUqhD3NRRKk9G9ihjjTSaX/fHOV280S9nk1x4vMe9557zzvme+/1eAUDAFBHBzK6chPEl0NOQ+GYjA9wWVNdE3twzQ8RhGIgZAlA6/9HzpP61FPorWUUpV44Om7zla9PJO7JiZp1sZlXkr68c+DX7rYMXDX7wJ9i+EjotxqMAhj7qRSgmX+HrQQRXnSooFs4Ac2/C338KL4oAmP3w57B1Y/vzdS+uyMU5x4F/N3EaOWHfARwDuYOQT9YP7UxVTUOcu7BSgdO/EPnbTTF7thb91qej9t2l0TAhIs4wnBRgoHiEDJPEbH4RIWcnfoxYhpFwVEBALSAIZqZT0xlTjSfu55XTTzrQSzrun9nd9pKSuBAg+EiFJU4VF9GQEwP4YZ9e/za7/Y/xwz4xgIacU8VFKiwRfCQESEnc7rYXHffPgF7KITYEJXg1xaTEMWMnNqnW5pitPMGDnQ+Zrj1DPvt9ANLuPxj2brF46ruoJnb6TYysRFsgeTVBBWIjB5c0QQz7PWIIglpkc/s2DmXu7Cqzjaug47Lciy+w2/4jXzV/jeJIGnGSlX2JkAJoAnApByeajOANMNQUM0WkwMc2c2evM9u4Svfebxh23gBgeuFn1M+9xKh/l+3mH3D5AmYBEYcTR/CGJgOcOABTiN4IQUELqnmdXKqY1Zh/7DqDzjv0vnyVGI0Yjd6XrzLovMP8Y9cxq5FLlWpeBy0IQYnesElz5QApWQkQkbOLKyzMnyX6Pl9s3sMVpxl0P6Beu0BlegnM8KOTDLofMDX/LHm+xLnFc+SVGToPmzQffIaG0udBAFUI3igkp3V/gwdbm2DK2A9Ifotq7Wls+C4OEOcwC1RrT5P8Fr2dTf4z3AFxpBTQlBF8RI9moKkskcsg+DFmI0RyUthj87NXOH/x9yT7kPbG24DROP8TssZzbPz7l4wGe4SQYRYREZzLiN4mIB8EMGIwXGaYSUkDYsAsG5/cpLbwDHPLv2O58SsQB1R4uPlnNj65SZbNkqKBlSdepfSlkxK5/RJ5r4Rgh49XUnT4UaT139cxc/zv9ip3117GVPjq3rv4YSRFR3hkr/f6aInKqFlumNkhf4miybG3vY6Io6jOI+IQl9HvfkFKEII+sodjGeQgppM2zQrD1I5QZMK0oL/TotO6xdzSZRBHp3WL7fa/UK0QvB6h8bKC0dskA7EcNEvJCB6ygoP+PaBoV6H3sEWn+T7ufAEYneb79DotKtM1LB4XJXEQ/H6bapZD0TYyYjCJwdAjGZSKoaSUMex3yfI6AMN+l5Sy8u/NOJqzcxCDSclNRdvB/Fp9udY6MVMxP1JNscQjTgCLwUjJaN55i6mZBlMzDZp33iKl4zYxGCkafqR6YqZi9eVaC+bXnMhrvdpc/cZTlx933fYo+rGppvJsaIIUDbOC0aDHR+9d5aP3rjIa9DArSNE4auvHpt32KD51+XFXm6vfEHmtd0wyH3y6eeWfb6+z2/VgphgTfhQMJUzItKiCUKq67NdSxM3WK3zvuRUWn1w+lMzjov/j53udnWubn3dXLEWcO667IlkJvR0HVtWQLGf5Qn29tnBqVeQvh6K/37uTCTO7dhLuX4L0La8t2RYsrYms7sH+FQj+D0GQMfsz1hm4AAAAAElFTkSuQmCC' },
    'palette' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADMUlEQVR42l3TTWxUVRyG8eecubcz0/mowLRCCkEq9SPUaKlGJS5cCIkLDDGmC7uxlKQxwcgCTdHFhI02SiJ1IUFNFBIUicaoURduUT60LYuCaIO2MVZKaTsfdObec8/5HxdNjPrs3sW7/ClfLmt1+LD4fWN9VJoDkiTtIACK/+ZBo8Nwgduyp9T7L477clkrAN8/OsxS9Sj1lQwioBSkNHi/elUKnKxuraGQi1jbdkCdGTmu/N6xXvP7HxPx/A0ShSUIFHGC1G8hYYgWD86ii3lUS4i31oeeIH17By1bNm0PbKU6KLU6dW9tKgwDqdXRHWso7N9D610bcek00ZUZVk58i5tfQhdbiUxiw1o9sJXqoHYmKTWt8YlGNSs1VF837V++hnvobs625pj7ZRbd1cGaT8qovm6alRqJRjWt8c4kJe01ziAqajZxpQLr3jtE5Y3P+enVkxx5eBvfT88RjX5G8vMipXcO4koFoqiBQZTXOC3ilUFoLFco7t1NfGWWSE6ztXeB/cNHuHd8kuCpXZjz12j+OktxaDeNpSoGQcSrwAOxsxgtpO/vpnL2IuufbdCYWWbDoQloD5j94lNc5Rbrwidoe/xBYiXEzuKBQBCMt0TO4jXYpuPC65vJmCyy1uGNIaUVcbVKm/IIQiwW4y2CoL2AESGyhuqFKfJP7+CbN3dy9Zke/GKFdE8X3W+P0D7wJIVH7qM6eZUoMRgRvIAWhY+tQfJZpt89TbGzk131TWRP/sDy0iI+n0VlWugaGSJ3zxamj32MFLLE1iAKHzhxqcgan4SK6PoNzg+8xI6xMrWXDzL/4yVwQnbjeky1zsXBV6jNXSeVzxJZ4524VJBJZ26KUqphYt+SzzJ3bpyv9wyxdV8/pcd6Abj81gfMfPQVzflFWop5Gib2hTCrMunMTeVfONE7ee67iUvXpkgFgdVBoFxsSKp1VCq1qsh7wkKOVLoFsdY7a4MH7uyh99Gd2xWA7R8dvvzb1NGZhT8zibVorVbR/DsRRDxhEHBHe2e0ravnQHBm5Lj6h/PzH/at/DU7UI1X2jUe8P/jrLygaEvnFnIbNp9Sx54b9+Wy/hvKUazC8i0IawAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAF8UlEQVR42pWWbYxUZxmGr/d87MzszLAf7C7LQsFtgFagDVKUFNtCRWtp/EFE7Q/ThvhDI4giX38MsibGGPmQiN3ExBppxbRWE01TbKkF0zYhSmFJjAEJLNnKx7ILsx8zOzPnvO/7PP6Y3aCNJvVJTk7yJue+n/t57pP7NUyXgjGguuU3BVxpJWo78Z4PVWEIJh4laj9n+r9UmcECMAoGFINRffbQLmrpFl+p9IYCmA+Hj4IPICwUrpJr6jcv7DigqAGD0X37Avr6lC/vf5mJ5Iv2xjUSm6AgMx/DfyH7wLmBIBNniHvmQ0vmFY7tfpq+PmMA9Jkf76BUPli6/I/UNMWRCYKgAaIQBBAY8AJuemRRCGEAoiDSGAigIqKpde2L7muivbjTvPjtQ0Z3/7zoLt+8WBu82l33FmOCALTRYRSitQSt1iGXwbQVMQo6XkZrKaY5g8llGsSmoUNVJBvG5O7tHY4Wzb0/YjxZ6atTPRNJVcMoNsh0l2GAlCaIFnZT2PwU2fWrCLta0ThGboxS/9N7VH55HDc0TNBaaCgEMCaYSKraVJ3qicaTlREiXYEXnDhVDQ0qEIZIaYL8pnXM3r8Ng1I9eZbbp8u0D98mWNpLfvNT5J/dwO1dR5j63SmCtiIN1wV4cRp4MYh0BRB7j2JVcOJxASRjE2Q3raXj8HamTp3h5hPbeH6oxHcf+RivleqMb/kRVz+9lfLxd+k4/C2ym9aSjE3gAnDisSp4FIh9QCBGVLEiOJS0WsfM76TrwDbKJ/7Cta8foTaRcHvVUsrzZzP6wGKYPYtZj6zDvj3E1MlzdB34JuaeLtJqHUcDS1QhEBMBCIoVD0Zx5Qod39kMotz8wVGaPwWMOj63t58HVy9h8Vt/xXZ10b1mDajhxovHyD28lNavbuT6np8QZduw4pFpHzcItDEinEVyMcUNqxk7PkB26RALDnnSyyHpNqH95SHSWVkqd0YYefMNwuZmxs6cpfjOAMXPfAKfi1FnsTqt4C6BYNWDTQlbCzR1dzB14SSpNWgS4GuGWhjiWpsIEFBh+J2TYAxeLFMXrtKyfjW0FrDlKax6RGWGIERQnApGDCICYqBZKJ2IkM050jtKUgXTZBEC8B5fT4kKeXxg8NLo1oogIjiV6RGFBABeFSsOHxpqpRL1W7cp9C5gbFmREzs+y6W1i8AnOMAmCZJtou3JNdDSTDJVpXn5vdRvjlIrlfChaWDpB3cgQhhAUqky8sa7LPj8Bob9ANcevYd0YYY5r18BazFxwEcP7iTT04kdm+TCrgO0rfs414/+gaRShebsXRdBQ4GgWPVYZ9F8hsEjv0byMY8te5zOPw4w72cDGGk4LerppGXVMq4cOkrc3sLy/r3gPYP9L6H5DNbZxg6YITCBNhR4rPdIJmZy8J+c/8b36V3yAM9UVjD39SEmxseolyuMnvkblw4d5b6+rWTndtLcO4/z23/IxOD7SCbGet+wqSqYQCMwoVfBqhCqR63DtOQZPPYqDuWh5/by6BfWM3z8bSYvDqKi5D/SQ1Roxo6XOb9nP0MvvUZTWwupTTHGNP5kFcCEEZl4RIMAp2KcCqoKTgjaCgwee5WR0wMs/trT9Gx4jDlPfBIMVK/d4uJPf8WV539L+fL7NLUVsc5O54LBqRgNAsjEI0Z3/75YvnT24lvv/bm77h3GmEBnFhSFuFqCm6oS5bJk2ltQIC1N4mt1wnyOKJdBpnPCGIOqSjaMWL9q3XBxyUP3B2b/xnKxrevgmkUrgrFq2aXiRKYX75yDTEzc0QrZJmqTZeqTZcjGRB0tkIlxziEoAqTiZKxadmsWrQiKbV0Hzf6N5VD37Qs4vOd0/s2/L52Xb31w6M6wmaxPkTgribOa2FTraaKJSzVVp6m4u2c21cTZ6Sc12Thjnlz+cNg9b+ErvLB9Zx8E/xn6X3lu12RpdMv1Ozd78Q6D+bfw/V9lUBTCiHmz516d1d7Zb36x9W7oz+S2Tr9036kC47dW4mr/37Ulyo3SOuec+d7jFWauQMC/AIqeXK/2i9c5AAAAAElFTkSuQmCC' },
    'serial' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC9ElEQVR42lWTTWhcZRSGn3Pvd+fOzJ2MTZjgQoQki+B/bboSu2jBhRtXgqBFMYvSlZhmIxgwpLQqAbEVXFS7UCEuFBVd1ZVd1KXBBqPiwsafWkuCTWbuJHO/v+NiUqlndRbnvLwvL48sLmqytCTx/fN6eLfPcefieAgJIlG4Y1QTTdNIliWbzYKVEy/Ld4uLmgjA22f1ZG+Hc/0+9RhB/vd6pwgkCRQFg5G7mDu1IBfk4nk9tLFhVzc3K8B5ERFVJcbhMfDfLiKoqkJmxsdzJiZqM8mtbT9b9hTvS68440OVmsyl8wtFOjoW0tGxkM4vFKnJXOpDlSrOeF/6sqfc2vazxrrQqeyehmjFV4aqSjBZwtR0zsAOHUxN54QolGUkzwMiXiq7p9Y1OkZVQ4hWrHW0R3bojHVptQy2t8f46N8A2N4ud3duUNQ9/d023V6TWs2Kaj0YNEqMA3ql8MLTX3HkyLe4fotGT3jp+QBAo5cyN6tkRcmVK4/z7ofP0mwOQFtiUMU6R5Z1+fjLJ1j54hitkRrL79zH4uu/AHB6eZpXX/uZsmeRJCXLuljXBlVMJOK9xfsK7y2qgRAEUHxwtwskBIcPFokp3oP3lkjEaFRUB3RLOPHc1xw9uoorCxrbCWfm/TDCtuHNVyJZq8/lyzO89d5TFMUAjYpBorr9CB999hifX3qYdjvj9BsznF2+CsDC0kGWzqzS7TrKfoss6+LcAZCoJkZNnatUY8U/24brNw7Q6eTU25P89tefANTbk1z7fYOtrYpGQxEqnKs0Rk1Nnte2lCjWDTTLDHkt4NyA9bWbJFICsL52E+d2yGseSLHOa5MoeV7bkk8v6qFL31xdXfvhezKTeklENCohQjpEhRCVNAFJBI2qzgfzyEOP8uSxgzP7MPmT6z/+dO6P6xt17z2CgAzhgX24FBTFGMO990wMHnzg/rlTC+aC3Mb5kw/08K/X+sd3d3vjGhNUEPYFEBBFJYk0myObU5PFyjMvDnH+FzzBoPx8t9sOAAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFTElEQVR42pWWX4hdVxXGf2uffe69c2cm4yRkMpn2oWNCE6QSO7TF0EiQvokPQWlT/70UEW3ogzEFq+DEByGSpkpj44NFpPhifFR8sRpEEbFliEWk0wanNZM/TNSZuffOvfecs9daPpw7E/tkXbA3nM05a+1vfetb6wg75gLily/7RP/fLKSKvaq8L8syiDl32rtZeuIJ6W37AhBwcQcR8R++4GeKoT291fN5yPj/TBmfkJVmK1z6yml53t1FBKIvIoBfPOeXtzo8vrqqFEWBg42QEURwwN0BEBEEMPf6jvUems3m/L33hvMXz/kjwElfRATgpef9dL/LheW31ssYJYZAYPszoCyckEGM9XNKjik0m3VgRrsZlpKnQ/dPN9qTfO3UGXlBXn7ZJ9dvpDff+ftgtkpDRCS8B7jC/IFIt2P8804Nau9MxviksHItEfMd/3Uod8tji/s+OHZ7+p54OOQFC/0tm9sadMTRoJpQS5glUkqELPHst6Y4+YU2w0HFYFDxqSfHeO7bHyBvJKqqflctoZpwNGwNOtLfsrm8YCFWxoyZkFLlWTAxF0RGwB1IUAyNRgugQs0pCiUEJ4sJHRgigju4C8GdlNTNRCpjJoaAutvoFo47mAXMBHBEBMhQVYrSUIOkAghFAWVpqAUEJwTDBcwUdyMENJoh5oZqhZmTNNBqDGg0CqoqJwRHvEcmBWOtTVQhhjEwaDU30cpothJl0WRYNomZoZowN8yQmAE1ghp+SpHnvvp9Dh5aJvXHyYLh63B4Cn7yPXZSZ9fhxUVQC8T2FteWD/HN82cQqTlxNzIgktUBkiaigqrz2z8+zPW13ViZI8E5dnyabiex9HoXN+eBI5Psn2vw+yvrlBVkzYq33z6AakUWlKR1ADKIdf3WKUoqiCR++epR7NePUiscHvrEh/jHzcR3L72JqvONsweY+3CbH7yyTLebiFEQjGazIKmM0l2XdKwhK2YVZoK7k1QwC7hvk1yrOKWSpL6j6JQqUqqAgIiRW4WIYFbhrv8dYESMCWWV8cnH/sDs7L8Y9luEYDT7V9k/XvLFz6zh7hyceQ3fGOdzJ24wHDpjEwW3b+3hV1ceppGP9OAjBBlgbqhVqAmqxmOPLnFo4S0YNEEc7yf2t4XPf3bUAIeKrTufPpGBBxgrWF66n1+8+hE0q33ZDsnbCKxCNQDC1889ydRUD9eAiHPxRx/l3ZUe31l8A1XnmdOH+djxfXz5qT+x1UvEhrOxMVELUR216i6CkONuhqaE1kXLVl/Y7E7VPUbAwhzDtMm7q5OoGr3hDMQZVm/totetyKKQBSXLSlQFTQk3I+R4NCOzEclqWU0sTh7reg8BxAsyKYmxTxAnCwXgNPIBMVbEKNhI4dsk1z7JYqvFWgiOWSVmGW6+3aUxq1v02FhOf5Aoqwocms0MU+gPStQM0qihOkgQzCoJwWm1WItzUyzt2T19s9lqz6Zq6BJCcNseLDAcGKe+9Bs21gvyvD6/9OJVfvrK3+j1huR5II1Gq4jglVmz1WbP7ulbc1MshWMnpLtvZvLCg0eOhk5nI1WpNHcdaUPJovOXq2vcWO2QZU6WOdevb/LG1TVi9FFjq1eVSut0NtKDR46GfTOTF46dkK74ogfO4i+d52cr79x6/M+v/45+v3N3ZI54cGBUGEios2i2M/QQCO32Lh556Djz9+3/+alnOclZ5D1D/8cX/czanc7TN2/fnE/VKEfvx9yJOczNzq3M7N116aln7g79u/FxAfyvV3zi2g0WhhV7teR//1woZA1o5dw5eA9LD3xcerVDcXD+A1oJV/P5ozu8AAAAAElFTkSuQmCC' },
    'unique' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADGElEQVR42l2Tz2tcVRiGn3PuuZOZaTM2yUzaxAmKYpOGpDUNoguLEKg/dqK4kCLSlRWstP4DRRR3Yjcu4iYIdhUCooKLLixSaAVrtKk1SeNorcakmdQkncm999x7v89FI4rv/n14No85o2rfNkaeX/5pfEvkWJpmNclSDMbwnymq1jnCMFyrWHvu0/4DV86oWgMw0bj62rqPzrbiuCh5jjEG3Tn+QxEUFKy1dBZLcW+5dOr8AwcnzYu3F8cWf1/+brXZJEl95qw1gmK5B1EUg6HDOjCgIiqBdXt7quyv9x92axut4612G99uZx+OP+lGKl18uXKLZ/bVudhcYV+xTJxnvDF7iU4XIigmybOtYsutbbSOuyxNqlkUqSbelBQmF+a43Fzl4p+3WN5u8XRfnZcffASSGKOCCqiKybcjzdKk6oxqrj41mnjamefb28tcW19jyYXcjWErdux23Wy1LZlXdgUpiKAdmTGquSNXoz5BvWe00k3NOgqZ0O2UiZ4/OHp/xHM1x1LvIilFLqxXiTNQnyC5GisqaJIiScIn83P8dqdJezPmUPgL02PfcDi4QNT8mNMDPzM1eokXem6y0RZsmoAKDhTxCRInnBgZI463CfMSR+uW65u7uVE4zVMDw7z6xUe8M/Q9PUGExB5NAhDFkQvq7xl8/WuDI311RqsPc6S6QD27BiaiErSoSIuQlCwVSBLEBzsGKprHCR0ivP7ZNM4o27HjlaEmJw/c4d3rV3nv2Ud5qPsgd5MfCSSDOEF9CCrqRCSQxKv6lJK1BEaJVfE+4FAt5oPHG/T693lr0FMLIz6/qeA9kiQqIoErlEpNq2IkipQwRFQpacr5RsibX9WphH/hsyYuMETSz8xSmaK0VfKyKZRKTdc7Mjy18sPcyc2lhnOFQmasNaBsq2HychG0/G8QKB1hpJJ5t6dvlN6R4Sk3Y7pmJxqzJ7D2bHP+RlFSD8aAQrlTMYDuRKWqEO6iZ3B/PPDEY6dmTNesQdVijLykG+Or8wvH/OZWjTxH/5ezQZUgoHBfZW3v0OC5abPnCqr2bzqAvCSN60cNAAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFhklEQVR42pWWX2xcVxHGf3POvbtre9fxpontOGmISdu4gabCRYKWRmopqtIiQYVUCuKF8kYKEmrzgoqUIgQCifQFyAMP4YWXUoGEihpaJBqoRAulUSkicVD+x3Hs/LHX9treveecGR52NwmCojLSla7un29mvhl93xFuhAC21+aqs8vtyVToRooCPP87ElAq4UvuymitfPSgjDR7WB1QM+nAiz06d2LfWoh7m83muDrX/e79hOFUqVarZ/ry7ODLIzt+2MOV/Wbu22APXzj2QsPL45fOniO1Whgo3TLkOkznXui8NAy5UazLK31s2vYBhpK9+OqtO5/YDyIAj8xMPX1N44HT7/69yPNSVqi6HmeZEwpVBCETQYFkSsl5MpEOdK8AMy1CET+4667SLS575vDYxPPylSvHaycXVqZOTU+PplYLL86ND1SJ1vl1vmgzUq6gBo1QkDvHUF5iprXKYijwNyWRbhJXKbN9y62zt9UHJrJ5PzC5snZ1LDYWrXAiHxqsc+T+PXgRLqyu8PPzJ/nmxN0A/OzsP9naX+Wh4TF+cvIY+979CxtKZVK3GAVExBWNJVu5ZW1sfsPwZCZmw2qGxWjmREiJaMo33n6DN6/OsRAKXp+9iABnV5YpVPntg59mvL9KKgpwHrObiBLBQjA1EzEbzizXhCopBPI85+LSIt/521v84vQJVlOkz2e83lwCoN9nzLdbTDWucbq5hIsRCxHDuMGTYCGCKpZrcpZETBVCpN1uM1oq8+yuj7JrsI6LCZ+UKsIggiSlYsIr0+f5/cULeDViiGiISApojFgMWIyYKpZEHPhOthixEEihU3UfQmgXWAzEIrLcUlwMFO0WX93xYZ7cPsHa2ho+dbpYaRnSAw8BVAFPhgdLioWAeE9RFLx9+RIzS4tkqhACreTZf/sxvrDlPJkJo6tvMZEZM59cRURoJMezx+/i8OVhannCQsCSgoesM35FQ8AhLK2tcmT6PAurK+SqaBSqknhyyzm8M968WqO0GDAcmRtATXhw0xyfH7nAry5soCbh+gwAnMdjqhAjRdFiY17mmcmPMVbuY35pkUazyeXFJYIKf5yr8KNzH6e25Xkqm77PD07cwfemtrHSqlAkIHSHHjoz8D2K0A5Fph5SAuDQnsf47p9e42v33EfURD0+ze7No9x75242DvXTCgNsyAKroYUXQ1SxGCBFNBadDnoUWVK0CORlx6XGAgf/+gaDpTKzjQZTV2YZyHPu7lNWQ+Sd6VOsn59lx+gnaLXbxKRdnehsomXdDrrPM3xni7QI5FnOfHOZp176JZhRyjJeOfEPMLj0pRbHG3N868+/47GdH2Fy66eoV9Yxu3y1i2+dBHnEiu4WeY8T78267WkM+KSsz0usL5UZEEe9VGFDpYJ3jhgS927ewZfv+QzXVhZ56r4vMuBKtKPiTKG3pjFgqoj3lomqJ6VOWzFhqujN4gUEg9UAe25fYffm1yg3/4CqMuwcP70/Ua0HmqcEQoCgnS1KCVH1mZQql70TiEkIETO9rv8KOKAVha8fGeFzdywiXZcQBDNDnLAcavz4nSEqFMTQwfJOkFLlclajdnRwdGQm7+8bTe22iXPuZvFKQFngNyf7eGmq/z1NrpQrZR+ILdO8v4/B0ZFLNWpH3SGR5fq2rQfGH3rArV2bj9puK6r0LlHFklLzgXXlgnWl/36VSaR2oa1r83H8oQdcfdvWA4dElmW/mXsO7JGZ4y9cPDb1+JmXX6XdWAQz5f8JEVceWsf4ow+zeefEi4fH7nziuY623jD9zzan9y2cv7h34eSp8RRCz1Hfh+cbPs+p37b9TH3r5oO/rm65Yfr/eWyxagMmI8sbY0w9tXrviJBlnozalSE4elDk344t/wIXADjN1aVVTgAAAABJRU5ErkJggg==' },
    'translate' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADDklEQVR42k2TT2hcVRSHv3vfm3/NmGSaTNLEFG0wiYlCa4oWtGL3kuLGhdRNS6ELFepewZ0LNxE3dmNXEUSEbroTqSg2KK214p8EkUqaxDHTJpl589699717j4tpoWfzW32HH4fzKUQ0SoVX/5HjHQlnbO6bFICgeHQUQgyVUrQzqPTK1SfUDUS0Ajj1l1z4L3PLHeOqIQg8wioFIv3UEhCtGayWzVitfPHaU+qSOn1Xnlvf2rvZureH9r5QGvVwhQCIQinBiyYLZQ4oKxLpeHxkmNnJ4UW903FnO70MlSaFKlwszkXKuaifNoqKLNrPdHSqejv6oPll5PMiVmlSdHoZOx13Ni5cPuqzVCR3KhT96rGGzMc8WW2zfOQrcokYjXssjtxiI63z6daLqpolUrjB0RiCF2eVWAP9k9CyOdUoYquo8NYfS7RsndfHf+VEd4wvNheohz28G1YQvJYgSqxBrMFbA87w2ckZliYfo9PN2E5qvDv1LdPlHc7dOo2xOcpmBGuQIEojBeIMKrf0koSTowO8Md3k/Nw4wRTMlzd4+/AqU9U25ydW8ZkDZxBnQAo0QQjOgrP4Xsq5+cf5fG2TiQMVnmlUuZ8Y7uc1VlsjXNts4owlONNngqCRAM6SJl3mGjWeP3SQ/W6CiPDm/BEm9b80yo4rd6Y5GHU5Wt/Epv0WSCAWQcQadGG5t7vH+1//xMrP6wjC0YkRbmxP8NEvc3y8+A3WR3zy2wLeVMBZRJBYfBHhjPgsZXaswXuvHGNpdoof7mxTAFu7HT68PgPxDAhoHajqHoWpiPgi0qXaQFuJKN9LpRErDg/VSY2hVOQ0yxFx4aiyR126DEiXWkjxqREtQZVqA+14amHwcuv2oXf2/16Lr16/WZxot1U7ydjY2IZSiahWIY40Th48eBDJcxtPHFtkamHwsgJ4ea24cPfH75d313+vdpOUOIqolWNEBB8E4QEsgi6XGJ171ky98NLF7+biS+qhzq85Od76c/eMT7pN8YrgRaGB8IjOOlAeGtoZf7qxcqXc1/l/hLG955VTMfEAAAAASUVORK5CYII=', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFTklEQVR42o2WW4xdVRnHf99ae59Lz5kyF2c6U6aFcQrTVsFkJPHCJVUR4QEwMtUHifLEQ43BACHxRXnRh0YIJNIQo/GFaMgQmmIMpaTRRoOQlDESM2OQdsoU2s6Mw1zPOfvsdfl82Kd2jI3Metk7eye/b33//17ffwsACBAFRA/Oa72dMh4d/SFnS8uWwKQslh1TkztkA1TAKCiCqhQ1RO/6QB9vuHCo0chHoil1Cm9lKSbm1Gql2Vpqj5wYlp9d5sqPVc2ToF+Z5cVly8EL5xZxWQZo3ApaAC3uTFqpsPP6fnoCkydH+NaTIALw1ff10UXlqdl33svT1CYiYj4OePnq1VISjwJRic4FP3LznlK/8Njr18nTct+idi0u5v8488GlwZBl/H+4IqL/JVyv3eB83kfZOAxKVKKtVBgdHrzU31/am0RlvNHKduary5okqWin4avt3KmhEUpEhIiQSuTEp57jD+tjPDE3wXabIYjJV5e10de9s09L44mHgagQXa4Kovq/BYwoWUwYrSzwy7Hf4DRBUJxayngeGT5KEj0/mH2A3rRFdF6jIh4GEmMIxADOFZZ0CihgBEznmY2B5Sxlcv4mqvayHMJ3h07jfJ2ptSFsaKPiC1YMGENIDIjGiPocNULRgSII7RjZcIGyNdRTy0pmOXzujuIzd1VAuaGywLF372Fy4TP0pesEZwtWjBiQBIAYUJejYlBVRCALkeu7Kty5Z4B3VxqcurDCtkTo0TapCXx/7E1u/cRZDv/zyxyfH2Og8i9ylyBSsIihkBdAY0CdKyr7HBM8zVaL7+2/lmdvvZHnbhsjVU/0OeuZ4fn9r/DEyCnemB+mkSl1WcXlHRW8K1j/KWCBeOUl3tFuZ/SlwsToDo6fW2BXV5UDg9tZb7YwISdRx/nsGrYZ5Ve3HOWBgb+z0jKFB77YKDGC7XRA6JjsHCZ4Gs0Wd17bS3+1zEO/f4u/Lazw0L5d+HZGcIG3lnYw2n2JT9c/5KfvfJ4/zw9Qp4HPr3AIRQdJIVEsPLAWFdA8Z+KGnYjAb+/9HGO9XYx21+grlWj6VX649zSvnNnP/a99E0oZSMTYQD1xRDEFK8bNEgWizyE4ms0WYz01Jvbu4qWZ93l1+hzPvjlNT6XEd/YP01pr82Gzzi0Dl/jS8DQ3bb/AweumeXD3DFmmmJAXrBjAbu6g7dDEg3fYGHj42J94eWaOpdUNKKVcXNvg4nqDkirf/uMXeeYLf2HywAmykGASx09Oj+NzD8YXrE4HiViUGFCfE11KWWD67HmG62Ve+MYd3PPr30Ez58jxN8BaKt01/jpf5/ajdzFQzagmno+yMmsupZY08bnpmBwQiyZRsBpCZ+eejWbGIwfGeea+25lbWefn996GMQZrhFbuOXzqbT5qNEmsYbkhLGlKYgJ1cUQniDXgHRoCUbBJWmXBGkG9E/WO6Nr0VYrzlznPYK2MNcUBLNerbBOYz3NsYkk6g1G9EC4PrmhQ78QaIa2ykPTCVNfg0IVStTboWi3dllrzo5dPspG1+frNNzLx/EuFYZ0pnlTLlIwhuHCVkSuo01jaVqNrcOhiL0wJwNeW9NG5t997auaFX+Tl7T2JSaxptR3dtSo+hCvJqRBUUb36PFcfYntt2e978OHS7s/ueey1Pnn6SmTO8eLF6ZmDs68eI19bwaDRh4jI1nJZxJhSdzcjd9/P0P59kyd3X47MTaF/97I+vnp+6dDKmbMjwQWkM/w+PvKVJLV0j35y9ppdfUeO92wK/U1JK4AeUq1fgvEA/aG9xd+WMlhYHISpIyIbBVAUlH8D0kvoLEPDKPoAAAAASUVORK5CYII=' },
    'report' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC4UlEQVR42l2Tz2tcdRTFP/f73sybZKahpknU1gZBY5VipWlVKtaNOxdCoQs1G4tKdCEU/QNiFi4Eha7ULMRuguJGV25cKOiqYJCqi1qVSrWxk0wzzK+89/1xr4uJoh44u3sOhwsfWVkxt7oq+sqndmJUsRSizqIODOEfKQlnLlPquduaLFh/74x8u7JiTgCe/9iWOz0uDEY0UgIf4d/xeg6ZgBo4B61JygNTnL/4jKzJq5/Z8V+u+432tsdSiBOFyPy0I+m4xAx+30kMK5ioCTGZ4Wr53Eydew7XF/NOL57rDwwJgzj0kj9xX8Fbz+5js6uIQKMG/RJe/mCHzW6iWQjBV7E/uC3v9OI5F32aCVVpmoL4qqJZV37aDLy01ubF99t8+GWfAy14e2mK/UWkLCtIQUJVWvRpxoEljV40VGio0BhJqtzsDGnfGvHnrZL+buLoXTXeOLuf0bBCY4VGL2ApN1PR4EnRo0HRFMgdPH2yxXTLMSwTy+92OP1AjbOPtcjMEz3U6h4zFYcaGj0aPCl4NEVMjblW5NB0jlrBo7d/QsE1hj4br9y7RY1cTccFsUJDwlJCLbL60YAn7/+OMw9d4tTDP3JlcJAynMRSiZobZ0zJwdDg95xAAyFmvHDqGx5f+IOjd16n3ZsiJEEskYJHnEODB4xc1CztTUohjp+YjOcWv4Bsiq3eJIXbQWJA1dBQkVw2LlIzl0wzDZVp9CRfIRYR4GZ/mu5oiloGIo5dX1DL9tZGj4bKkmmWNxr1bVBJVWkZxo32gCOHJ9idfRMnGc4pmpRD2SQ//NrF+0CRBaO5TxqN+ra89pUdv/T59xtXNy6T17IoIjJ/R5M8rwGGGYAgKFvdkp1eaZY0X1g8xiNPPbg4hmk9Ll+9fOVC+9pvjRgiPhiG8X/lmVAUdebuni8Xjh05f3EpX5O/cX79aztx4+fhUjXoz0KG/IdHEMEUo2g2tw7e21x/5/QY578AXAPTsHdjj/YAAAAASUVORK5CYII=', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFBUlEQVR42o2VX4hdVxXGf2ufc8/9M3dmbjJ3OsmYtKRpwWgpZdRiQUTxyZaKiqkt2qJSGk2khaZ9tbEgvpiCaKqGYkXwoaZooVYoPrTUtgpCQCNUaEPVZDKZTCbJZO7fc/Zaqw/ndu4kttQNm8OBvb+1vvV9m0/YWC4g/thL3ryUsxAjs+T8fyuDNGWllXH8+5+VzrtYAAIuOCDi+37vj/SH7O90bJdLKC/L+4D6lb/iRrMZ3q5XefIXX5If4S4IyGPu4RD4/b/lmfXI3sVTBflwCGAhvD++OfiVRUJWrfKhnRUmU449dRdfPQQiAA/8zh++2OPwW29czCuZpAEJDvSGjhrY1UgiNKpCloLauAnHLc893rBnS7alwcGjX5Yn5NHnfPLMWvzXyf8OtulwgIRyNlGdb39ugh0zCe4QZNz5et/41Ss9Fi8azZoQ9d1Wwc0tqdbYfW3t7Px0+uE0Zix0ezY/XL/saSURiyX1NIG7P1mlnglLl5RKIhuF5loZt91Y4Vs/X2V5zZioCRpHWghhuH7Zu71sPs6ykBbGNeqCxcI9mJgLOEQr6R/7a5fDf1ijPZkwLJzWRODoA21mJwO/3LeVb/5shbMXCyZqATUnCFhUVxcpjGsCCYoZphHTiGuBaYFrQRCoBKeWKNXRriVGsxb49ctrTNWFp7/TZvs0DAYFmG7gYAYJGoIh7obGAlPFRwdMI47jbsRYEGPEtKDTz1nrKfd9ZooQhGvbFQ7e2aLbz8EiporGAncjGJICuDuuEVcB99J+G6IZFVGCCSmORePBo6doTQhrXefxr80zO5WMmBvuUmKNnJeSlCBl12UB87ErVI3H79nOzbsa4Iaacv9PFvn72cAwDsmjYuZojJiWBjGNeDki0rJNxbX4XwZeuvvI82e4fluVYUxYvlxnqrLM9+75DT/+053kcTdBBqMJlAVcC3AdMSi9i8UCS65m4AScN0+vcWqlwY3t/3DbdW9yebiVj+95nfm/fIw8JmTBsFjgsbxrscCtHFEoCyge46iL8QYwM1KEqHVu/8gJHvr8s8zUL2HdFp1hhmAlay3Gd2PETTdp4IZpgWm4gkEQozvMuO/WF7nlujX+vTpDvj7NIE8o7VeU4DgWSw3NKW3umzUwG1VP3tNFCzve4qb5LqcvTBNwcBtJZyO3jF1YajB6B0BaCbi7oRqxUYHNLsKNaIFeUUVQksSoJAUkTiKbGGixwUA14m5UAh5cSdxKkcpDcfSSI2ZOf6AsrlYYDHMWz1fo9I2l1YTueqDby8mj4u4b90yLkciGK0ma1DgXxMAKcU3BraQpgruw7wvb6HR/SKsR+fquJpNbvsH+e7cy0d7LoQNT7Jxr8NqJ3qYRCVghQYykxrm0Pcvx6XbrTFZrbNN84BJCEHH6A+MHT5/g1o/OAAlOoJKcJ48pWXqOV2NKJbnAa/9Y4fk/L5KKYipoNMtqDabbraX2LMcF4MAL/vDJf64e/tsLz+X1ZjMNSZllnX5BEUsRBS9TUK7+CtUs0KilaFTrdzrxE3d8Mdt908zBI3fIE+PIfJZnTp9c3vvGq68w6KzjjiWBTWq/9xLKxDMn1JuT7PnUp9mxe+7YU1/ZiMxx6B/4oz9yYXl9//lTS7tiAfIB4Bv5705agfbO7W9vnZt88sjtm0J/3IcL4D9d9ubSaRaGfWY1B5IPQFdIMqjWWdm+g+PfnZNOCSgOzjuOqWDP2gz7yAAAAABJRU5ErkJggg==' },
    'pricing' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADOklEQVR42lXT3UvddRzA8ff3e36/43nw4bh0oK3mnFuRBunootHF6AECN71eMsIxSIJqXay7Oqw7I3DrYhCMwS7MWFcjyosRBAvC5UxMrLl0M0+aj0f9eY6/83v4fLqoBntfvf+Bl8lr3l40F+XN0pVjnin3BZWgkVgADI+nJCzJquRajWaGv8y+czeveWsAerc+fXs92L7k+aWUiGCNxWKIEQASWARFVLDWUpPK+g3JuvM3cx9+Yc5UrnTeX3o4sbq5iomJHOuYcuxTivfIJtIAjz6TSBFJpJrA2b9vP0eaW7qczZ2tfq/soaUoch3XKYZbdFQf4lxLN23pJgD+2FvmauFbpncfUO/WEPhh5KU8Z3Nnq98GYdgQlQJNhJgNr0hP/XFG2i8Qlxe5MXeNG3PX8EsFRtov0FN/nA2vSCLERKVAgzBscIxoTCjGK3m017UwePQtPpr8mDvF3+hvTFKXEEbmxxhf/YnBFz7hfnGB37cfkku5xojGVlQNgeDtegwc7OVWYZTxlSkuP13LqVpDe9Lh7L56JlamuFUYZeBgL96uB4EgqsYiQuQHZOIkR7JN3FkeJ0eaZ6oqOFaZ3TN8tSJkNc343+O0ZZvIxEkiPwARLAJSiRE/QlUxkRBWhPMzlplt5bVcxFBrQFZiokAwqogfIZUYBCyqmEDY8XaY3SzQ2dBFtFfklSccViuWubKlznUpl7boauhidrPAjreDCQRUsSqqsR+SEZfPx4Z54/BJns11MLW0wFNOiUqlxJnbf3KguoPutpNcHhsmIy6xH6Ki6qhoIvIDTUuSycUZ3h8d4rPXBxmevsnt7V9IJeDE0U5Od/Tw3ugQk4sz5JLVRH6gKppw3HTVuhFMUPY1V5Xl68nvuLc8x7svneZw8wAKzG8s0H39A6ZW7lGfqSMo++rWpoybrlo3Z/V658/ffD8x/8OvuK4TOY5jdoM9/LBMJpkBoByUSbkZqpNpoijSMIyc1hPP8+KpV7seYXrw4/SltZlCKg4irLVYY4n1P0zGIiqICImkQ+NzB/xDL3f8i+l/zud0+NhfS/N9/vZeIyJg9HHOahRrSdWl155sbh2+avru5jVv/wHON7vWrdeBOAAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAF80lEQVR42o2WX4xVVxXGf2ufc//M3HuZGS9QZuhQxmGQArXpiKamfbGmirQPpAapJqipMRpKbQfGJjYxoI2J2hZDaImkNMSXaiFSwEoLxqIPpsQ/Uwk1jODM4MB4YeC28+/OnHv22Xv5cC7QvmhXsvfDyV7fXt9a3853hOuhCIJu1gPFGaZ6PW6Bq8dAwP8OR5DLYgiuFpk3sEe+NHMdC0BQBBREdEO0u38umdtcq9W6fAgoIP8Hv3HGJFAoFEaawqY9B/OPPYuqgCDbdbvZwQ59aGbnK5OZaENl5BJxVAfU30QR5MYOiqblNfbGGZPN52jvupUWmz94qLh14w52iABsiHZtrerMc0OnB+NsmAlFxFxPC8SgQN1brCYAZCQkZzII4N5Xh6r6OLFJ950rsmUpbjuYf3ynPKL7SpXqlcGhiyOLfGQREaONao0Ik0kNQejMzac9VwagUq9ysX4NRWkJC3hNOUnjEpPP0N3Zdbm9fMuK0OJ6a7OzHfHErIaZjHj1iIBXmHSzrJv/KTZ3rmfNvJ4b41Dgr1Pn2XPxMMeu/ZlS0HwjR0RMPDGrtfJshy273hDcQq8eHyeqYgQFjxK5mJ+u+CZfW/w5RmaGeGn4RQZnRlHg9uISPrvwPvav+i6/GDvBU4P7yAfZVDoCPk7UqxdwC0PIOLyiiUfFIwiTdpqf3bGFTYvvZ9c/n+d45XXeTeCTzZA1sHd8gAP/PsyDHV/gOx/bgvFC35nnac2UUgEkPqVDxoWKF/WKxg4xykQ8zbpFd7Op8352D77AoQu/pjW3kBU55eHWiKJREp9nygkHRw4hKjy24lF+V/kLxy6fojVbRGOHekXxqVrUKd56vHVgHX09G7kwPcxvRo5SDObzYGmOF2+bYk1zTHfOsqtziq+2zVIw83ntwlEuTA/T17MRrMNbh7cedamEUzl6D9YTRRGd2QXc1dbNG6PHsdbR5D2b5secrxl+dTXkaDVk3ZkmXrtmyHtHYh1vjJ7grrZuOrMLiKIIrE8xgRBAvULiidXRMS+V4tDEMBkV6tYxVhdWljzljDJu4RMF4e1pweAIvDA0MQRAR7bMxakr5FyQYqYMAnDpDLx16YBQcIokHmc9Px42/LEq5I1yR1F5ennMD5daSHy6nKbvO0nbrLFrfAvSFqlXnHVknHBp8jIgfLS0lKge04QyVlMeeVt4+ZLwyphwfMzQ26a0Z5SZKKa7tBRIczNOcNa9nwHgPD5OyPqQkeoYA+PnWNu1Fp8ogfe8sFrZtcrT26J0NymrW5T3IqjOeQKnfL5rLQPj5xipjpH1IT5OwKUzMEGDwfX2qHU8c2o/Xa3LeKhnPReqFX5/WViSN/QUDD1Fw/lpw/fPGIaqFb64fD1drct45tR+tIHhGwwCIBSMqlfUOpLYMi9o5vDZk+y/7Qh9n+7HOc/edw7xdOT53uocpVB46u8RtzYbNq1+mCfu7mf/6SMcPnuStnyJJLbpRV4RjIYgAc6jNl1OlZI08fixn+ASR/+9T7Jh1Xpe/cdvSZJhZozQt6aL9SsfYOlHlrPvb4fYeuJZSkETLk5ABLW+0SIJwgzZcSMGtV7UetR7RIQcIY8e/REnzv2Jvnu+zhP39n3AZ94aPcOTx7dxZPAPzMsVIPF4VcSkWEYMGbLjYSuFgZaO8n+yhdwiN2dVAjHa8JGWoMCRM29y9J2TLGltp7PlFgQYnbzC6EQFVaUlX0pfbupL+Nj5bCFHS0e50kphQAC+rD/fOjJw9rnTL70Z51uaQxMGNw3HGFSVKImxrmE4QUg+zCIiOH/TcHzifDQ5m9z5jfuyXb23b/ulfHtnsF23m930v/V669mVzR1tH3/3fEXqEzWSudgnc7HaWl3tXKzUvQYWDSyqkVM7V1dbq2sSxZrMxZpEsYTNOVm58Z5g8aqlBw9ktmxjB+YDpv8V3dv/3tjVzdV/jXU5mw7sQ4UqQSakvGzxSNviBXtelm/dNP2Gp3Pd8bbryWKFam9CfYHjQ/62kCUkd7Wd8sAP5DMzDcdVFP4L79VJhWFuScgAAAAASUVORK5CYII=' },
    'walls' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC1ElEQVR42n2TP2hdZRjGf+93vnPvubnJTVvzx+AgSAuCRU1KS7GuKji0c8nSCNrBP9RB7GRV0EEQShfJIHTpXim6CG5BaNNgBzuIbdUaJc21Se6f3O+c833v62ArCMVneabn4XmGn9g5c/KRqL1jh+ixqFGnUQCE/8pw4LzbpMMluSDX7Zw5AbBTdpotzrNNQeL/lQF7COzljFyUZbG3bT7cLtdGG4HUSVGaImCPGPBgRmmW9TLfmi0onmou+LgTl+rtxGB8GOe+nPFmPDqvgAMR+HPpXvTbufc7ccnHOk4Nq6HVY7WYM7oXttB+glxA7OF7SIK0hOl391HntQwHQ8trN+UVUtBKQirRqIx6gX0n9lAcaKG7OWSG+ITLEjiBHEajQEYuCsmbJQkaKK1CzYhZTfFMwR/Ld6D8BRqeujtB9VcHyZTUh3InkBcNkibxakqZKkIqMYxKK+qBMfh9g8eOXqExlciaJT+efY04auInSlLdoGiWmCouYQQtKfVhQUQakUGvzQ8fL3Ljk5O4NuwaTJ+4ypErn9JeuMmwb5AlvKIELQmpRM2orH7ggarokbcrNtaeYPaVaxz84CtSmTPsG8YIRXEYFlKg1AozpYwlD29VLrD56xhbt/by/IeXqXotvnv9JHevz5GKPiliLmrKRhosWAkZpIYiuRCzivv3Kp48/j1HP7tMtdXm2zeP89vaFDaxxW5VWVLNXKsouokkozQy3/bMv3cQ3864v77N3EszvPjFq4TuON+89TJ3VqeQzg7DsrIkKkWz2RV73+ZXVq6trdxaZXJ2PCIiFpXe3T7zbzyLmXD761UG3Q55K6IJq2P0xw4c5tgLhxcEIJ6Kp6/+fOP8zfWfijrViDhc7qh3a7RW/FiBbyQ0Qe5znp7ZH47sf+6Mv+iX5V+cz9qhnfX+Ym/Un3Y4LJpILjgHGhOqYibGZKuzOfn4xCX5/B+c/waDDapt1AXoOwAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAE5klEQVR42pWWW4xdZRXHf+vbl3OZM/Q2M7ajQ1OE0AoEbEDFB41EAphIMJHY8MIDSAL1wXB7KikYfQM0aiFRn3whpQ3BRAkkkEBIihAdMUSwCJTqOMXOpXPjnLO/y1o8nD0znURpXQ/7Ye8v///3X+u/11pCHYaJIGYHrcMKewmMkji/yICCGTpMyiOysooFIIYJgCBmd9v92tV7bMV2ZZbx/0SShHTkhGu7J+RJeXQN1w6a42GMOznMCrf2pyt88pihq9o+PWTwFFyZlTTHG9DhCL/hezyMCIDdZfeywGMz7895jJw+7py4/42niSLE0c9vK9nMffIreVzsARuO0/Hvyye623vdLuWlpWt+s4nka5c7dxhYhP6Lffxxr612m+Fd7Y/y8Xx3TmRv6MbxhbBg0hO54LZhOje30Z6dP0kEaQqMGSsPfuyqYsGa3XI8j/neHGVMkhA0mKiIZUaaSXz04AzSEswbluxTU2N9Y8fPPoNlRtCAqZkkEZSxHEgJxWtEVFAMyyASIUKxvSAbyga1lv9BUBnSAHWG14AppIFHUo4haopXPyAwBTF8DJSjBTseGkMa51eMaroiEFC1AU6dZZIlgnnEBK3dGVMgLzKkIUz9dJr5FzzSaGBqCCBlJGtV6y520P9HHx0yQggkG/ylNYHiU1xTYAZREzEODi28GWhOPMO2G94nzrWRInLmj3s4/cI1uEYY9IGYkQ2BZA6vgWS6yguK4i3gLaAYYASLJOLAhS3FWwNtOLTM6Fw5zcSdL5NainYiXgpktEeVFB9SjaNnK0gbamBA1EisZWrZZeroF/n3S9dSzba5+I6XmPjuawSr6M2WTNz8Opf88A/MvbqHdx69Ba+eVDcyB4OKBwt4XWU2osW1PEZVdGgZ2ToHm+cpxuYpN3VZni357C3HuOzAURqdHuPf/jPZ6Cz9ylBWa5CBmlJp3KAgWFpTkDRSxQQeAp6l6WE+ePZKJr7zOlcceBbrl0iR+Nsvvs7i1DCpWCGpQraqoHZRML/uorMVMPjuY0KGl3n7qatYPLmFq3/8DNYvcWXkjZ/cwJtPfpVU9DYUOcdhyZSgAZRagRE1EDXWKYp49WQOunMlu/e9wVcOPo/W4K/96HqOH72c5rYz+JThUxwQOMxhZMkSlQa8RVQVjYbXSNSEJiORiBJYmoedN73Dlw/8ntRr4MrIq49cx1tHvkC2ZZEqKKG+TLIERpaTcRpnBIKICSbQHmty41PfICszXCZETXy83GPHtVv42qF9iH1I1p3klYM38dbTu2lvXaQKDkg4ETxBcAYZp3NGmBzbNDLdzlvbl/Nle/vIu2759AqpSkgmVEuek8emYEi47udfQmWEU8cuYupl+MvTl9DcvEQVBCMhIpiqDpVtxjaNnGKEycHA2W/3fvjB9GO//dNhP0QrN2/O6hYgDoqhgqKdc/X+q3j3d+/xn7/O4ooORavCbL1PJVVd6i3F26/ZV+68aPw+OSSPr4/M73P4val/3vrc8RdZqpYwajsZmCqm0FusKFo5RSsHFFNZH5oibnPzAr6153ou/tyFR/h1PTI3DP39dv/8mcV7Ts7+a1eKihO3oVu6TDAFs43zQU3JcsfOkYkTW7dsekIOnTX0a3DqF2a/tA6n2EtVry3nWi5WzzSYYQeT8gNZGewAYobxCWc6+WoYafX4AAAAAElFTkSuQmCC' },
    'library' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADAklEQVR42m3TzWtcVRjH8e85985LmmT6kpk02taKbbEIUZsoJBZ1odQUuxKKgQpSXOgqFMH/wkVduJDShWgXtlJXhSourCDR1KTQaahFkoXSJubFyWRe7r3nnPs8LiaCC5/977f48XwMqhZj5NRdHW8I57yXmuRgFcN/TgxqIygU7Ppey5XvnjXzqFoDMDGv768lXNzuUhYBDBjA7lSIggIoWAuVXaTDfVz4edx8Zl5b1BPLD9OF1c2USHwAjDG9ZCvLARgoWqwxiPZqcluIR4bKPHWgPBY3WuF8sxOwaStgbRwZCKJ0nPDJySEGC4b3bm1SLhiK1pArWElDsxPHjVY4b4MP1TzpqrrMRCGj203wScKNqSovVSOO9sOtMzWsS+l0usQhQ11m8qSrwYeqRSRXnxnjU5pbLYYjT336MLHkvHxtiVe/XmajnXFv+kkOFnO2tloYn6I+M4jkFlFjfIZLupw61Mfc9FG+rP/FG5fvkjZbaKfNW5/X+fTXR8y+fYTTh3fhul2Mz0DUxCCIS8FlfDhW44v6Kn2R4fo7x8m1N2ZkYOnvhK8W15h5fojvH6z2MggWyVGXEYtj6vIvzP3RYOaFEe6vbrPSaLG61aL+qMm7o1WWNtucvjRHQTzqMpCcWFVQl4JLwQf2FISFlTYf/7jIN69fpT92nPnpLKP7B9kdK8an4AR1JVSFGEHVZTslntx7JFdKocXE/i1KpYxBbRKCIMGjLkELAq4MgloViTRLVH0KWYp4x3OPV/jolWOUykAcmDl5hMkn9iDBg0tRn6JZoioSxcVyacOSG9dN1FrLD/f/5OrtfRysVLg0/wwqCbWRKt/eW+b6/BI2EkLS1VL/gCmWSxtmak1P1K/NLjycncUWC0FUDYnvPX880IMR2mAUygWstSrOxQcmJxk9OzkW3xw2dyZuhw/URBcbvz8oawjYiu3JQXYs7gMMIoKJY/Yeezo99OL4hZvD5o75l/Ob6zq+8lvznG9v10Ts/3O2QmGgsv7Y8d1XbtR6nP8Bb6i24nMhNrAAAAAASUVORK5CYII=', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFOUlEQVR42pWVXYhdZxWGn/Xtn3M6J/PnmEw6x0wyKa2xk4qZ2JtWEqNGbTEOCKkFQSTeSPyhaPFCEAv2QsFY7EW865W0DCMBrVGwtukPhSptkCS1Q0pnbCZt0pmkM2fmnJzZe3/fWl7sczKTFIpd8N3s/e31rvXu911LuB4mIHb4PdvUajGReTaTATEfHh6oQCVmsVbj9PSwNLu5AAQzAUDE9r9uD7dyPdps2Zi6iI8STgObajJXS93xF8blN9288gsz9wjYvf9makk4/O7bGX4tw0DBbkgiCALoTc/LN7i4WmFke4VBY/rlz/DNR0AEYN85+/FCwbG5s4t5mrhYBHdzhZEImRoGVJ0QzD7QhRmaF+rH7tqcbkn4yYu75bfy9Tes951lP/PmfHOrZmuIyA3JDUgcNDKlXosQYL4ZGKg4/AcxMDN1lSq3b9t0uT4Q74qvVZhotv1IsbJscRLJzYUlTlhqBfZsTjn5lSGqkTD590VeeneNwZ6IQm+iUXDFypo129WRa8PxhNPAlqCgPjfzBd2DL4iCZ2mlzde2pfxzcitFMBbanhcPDfPgbVWWVtq4UN7d+K363IKCBrbETgiYQlGAlEQ6ATNorAV+uGeIx/cN86/32kyevEjbGyfur/PUl4bZ3iP8+tUr1CoRTkCtbIGiAFOcEGITBFXM55gzHJAHowjKY/vrPLTn40ydX+a7z1yk0BL8/hOz/P6LdX51zxZ29Mb84LmLxE5II0GhZEAVE6S0kQbMF0gkXMsDtcQxfWgnh27r59FXLvHzl96hEjuSSDAFNePIyVlml9r88nN1dvTGPPjnt1htK7U06gAE6PrUNCA+JzdjrC/l5AOf4o7BKt96+k2ePLNITzUCDQTtmAqoxfDoC29z/mqLqck7eO3bd/LVqf9wYSVDQoFdB4gAVfAFRVCGKikalAN/OMMXdgxw6aHPkjqHCLjS/agJBng1/vjGFQ4+eZbfHdzJUAXeyjMSC2XOqDtpNKB5TrVa4bX5JcaPv4JhPP3AnVxoZDw3d5VqnNIsEgB6Ek/hc+6u93F076387B/nGT++QBwJVecosnydoggwVazIsdiRmBEMIgeZN07NXuFHfz3P+FDB7oF5RIyZRp0zV27hp/eOsvfWPlICkXoSEUylzKVKtE5RKFXkHWYGJgQpFdebGD1Rle/vepXvTfwFTDgxs4/vPH8f/akhAlbk4H0pUwTznQ42UoQvwEdghllnSpmVgL5AzBOySjmJrXNfO3/d+1I5HQA2qkjArOuDDQAImBmttYzW0irNtaJ8KNDKAqtLq6y0B1EzLBSYzzBz1zswVQQsViFCQ+m+NC7taCAOIueY3L2NwSN93DMwT+TagPDl2wd46sjd7K3XiJ1DtNuBW3eyBlSI4qiHhUjAQiHmY6zjVp8FHj91jslPb2ei3sNyYyeX5kYAo/KxT7JnpIe1PPDYs+doLK+SOIdqQJxgoZBIIOphQY6Y9Z5+vjHz+ok/bdV8DXHirDNSQ+7LigxwaXd9lBGy9dmVxDgp6TM1dWmV8W9MXp74fP8u94TI6sBo/7HR/QdceP+qtzxX0YBoIE0cSSwkiZBEOYnL1k8iJLGQJg5nAdRjea7h/at+dP8BNzDaf+wJkdX1lXmWqcszc4cvPPM3/EoDzPQjLWURF/f1M3rwPrbuGpt++a7uytyw9A/81x5uXFw62pi9MBYKvZGSDwszosTRv3N0rv8Tg8dP7diw9LtLuxQ4dthsU6vNhM/YTP5/Vp9CXGGxdgunp0WaHT0bGP8DCJHfSPLb5x8AAAAASUVORK5CYII=' }
  }.freeze unless const_defined?(:DOLA_EMBEDDED_ICONS, false)

  def self.generate_tool_icon_png(path, size, rgb, symbol)
    embedded = DOLA_EMBEDDED_ICONS[symbol.to_s]
    if embedded && embedded[size.to_i]
      begin
        data = embedded[size.to_i].unpack1('m')
        File.binwrite(path, data) unless File.exist?(path) && File.size(path) == data.bytesize
        return path
      rescue
      end
    end
    return path if File.exist?(path) && File.size(path) > 60
    w = size.to_i
    h = size.to_i
    buf = Array.new(w * h * 4, 0)

    set_px = lambda do |x, y, r, g, b, a = 255|
      next if x < 0 || y < 0 || x >= w || y >= h
      idx = (y * w + x) * 4
      buf[idx]     = r
      buf[idx + 1] = g
      buf[idx + 2] = b
      buf[idx + 3] = a
    end

    draw_line = lambda do |x0, y0, x1, y1, r, g, b, thick = 1|
      dx = (x1 - x0).abs
      sx = x0 < x1 ? 1 : -1
      dy = -(y1 - y0).abs
      sy = y0 < y1 ? 1 : -1
      err = dx + dy
      cx = x0
      cy = y0
      loop do
        (-thick / 2..thick / 2).each do |ox|
          (-thick / 2..thick / 2).each do |oy|
            set_px.call(cx + ox, cy + oy, r, g, b, 255)
          end
        end
        break if cx == x1 && cy == y1
        e2 = 2 * err
        if e2 >= dy
          err += dy
          cx += sx
        end
        if e2 <= dx
          err += dx
          cy += sy
        end
      end
    end

    br, bg, bb = rgb
    pad = 1
    (pad...(h - pad)).each do |y|
      (pad...(w - pad)).each do |x|
        if (x < pad + 3 && y < pad + 3) && ((pad + 3 - x) + (pad + 3 - y) > 3)
          next
        elsif (x >= w - pad - 3 && y < pad + 3) && ((x - (w - pad - 4)) + (pad + 3 - y) > 3)
          next
        elsif (x < pad + 3 && y >= h - pad - 3) && ((pad + 3 - x) + (y - (h - pad - 4)) > 3)
          next
        elsif (x >= w - pad - 3 && y >= h - pad - 3) && ((x - (w - pad - 4)) + (y - (h - pad - 4)) > 3)
          next
        end

        is_border = (x <= pad + 1 || x >= w - pad - 2 || y <= pad + 1 || y >= h - pad - 2)
        if is_border
          set_px.call(x, y, [br + 45, 255].min, [bg + 45, 255].min, [bb + 45, 255].min, 255)
        else
          shade = ((y.to_f / h) * 38).round
          set_px.call(x, y, [br - shade, 15].max, [bg - shade, 15].max, [bb - shade, 15].max, 255)
        end
      end
    end

    mid = w / 2
    t = w >= 22 ? 2 : 1
    case symbol
    when :library
      draw_line.call(5, 7, w - 6, 7, 255, 255, 255, t)
      draw_line.call(5, mid, w - 6, mid, 253, 224, 71, t)
      draw_line.call(5, h - 7, w - 6, h - 7, 255, 255, 255, t)
    when :gear
      draw_line.call(5, 7, w - 6, 7, 255, 255, 255, t)
      draw_line.call(5, mid, w - 6, mid, 255, 255, 255, t)
      draw_line.call(5, h - 7, w - 6, h - 7, 255, 255, 255, t)
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(8 + ox, 7 + oy, 253, 224, 71, 255) } }
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(w - 9 + ox, mid + oy, 253, 224, 71, 255) } }
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(10 + ox, h - 7 + oy, 253, 224, 71, 255) } }
    when :grain_z
      draw_line.call(7, 6, 7, h - 7, 254, 240, 138, 1)
      draw_line.call(mid, 5, mid, h - 6, 255, 255, 255, t)
      draw_line.call(w - 8, 6, w - 8, h - 7, 254, 240, 138, 1)
      draw_line.call(mid, 5, mid - 3, 9, 255, 255, 255, t)
      draw_line.call(mid, 5, mid + 3, 9, 255, 255, 255, t)
      draw_line.call(mid, h - 6, mid - 3, h - 10, 255, 255, 255, t)
      draw_line.call(mid, h - 6, mid + 3, h - 10, 255, 255, 255, t)
    when :grain_flip
      draw_line.call(mid, 5, mid, h - 6, 255, 255, 255, t)
      draw_line.call(5, mid, w - 6, mid, 254, 240, 138, t)
      draw_line.call(mid, 5, mid - 3, 8, 255, 255, 255, 1)
      draw_line.call(mid, 5, mid + 3, 8, 255, 255, 255, 1)
      draw_line.call(w - 6, mid, w - 9, mid - 3, 254, 240, 138, 1)
      draw_line.call(w - 6, mid, w - 9, mid + 3, 254, 240, 138, 1)
    when :rotate
      draw_line.call(7, 7, w - 7, 7, 255, 255, 255, t)
      draw_line.call(w - 7, 7, w - 7, h - 7, 255, 255, 255, t)
      draw_line.call(w - 7, h - 7, 7, h - 7, 255, 255, 255, t)
      draw_line.call(7, 7, 11, 5, 253, 224, 71, t)
      draw_line.call(7, 7, 11, 10, 253, 224, 71, t)
    when :flip
      draw_line.call(mid, 5, mid, h - 6, 253, 224, 71, 1)
      draw_line.call(5, h - 7, mid - 2, 7, 255, 255, 255, t)
      draw_line.call(w - 6, h - 7, mid + 2, 7, 255, 255, 255, t)
    when :snap
      draw_line.call(6, 6, mid - 1, 6, 255, 255, 255, t)
      draw_line.call(6, 6, 6, h - 7, 255, 255, 255, t)
      draw_line.call(6, h - 7, mid - 1, h - 7, 255, 255, 255, t)
      draw_line.call(mid + 1, 6, w - 7, 6, 253, 224, 71, t)
      draw_line.call(w - 7, 6, w - 7, h - 7, 253, 224, 71, t)
      draw_line.call(mid + 1, h - 7, w - 7, h - 7, 253, 224, 71, t)
    when :door
      draw_line.call(7, 5, w - 8, 5, 255, 255, 255, t)
      draw_line.call(7, h - 6, w - 8, h - 6, 255, 255, 255, t)
      draw_line.call(7, 5, 7, h - 6, 255, 255, 255, t)
      draw_line.call(w - 8, 5, w - 8, h - 6, 255, 255, 255, t)
      set_px.call(w - 11, mid, 253, 224, 71, 255)
      set_px.call(w - 11, mid + 1, 253, 224, 71, 255)
    when :led
      draw_line.call(5, 8, w - 6, 8, 255, 255, 255, t + 1)
      draw_line.call(8, 12, 6, h - 6, 254, 240, 138, 1)
      draw_line.call(mid, 12, mid, h - 5, 255, 255, 255, t)
      draw_line.call(w - 9, 12, w - 7, h - 6, 254, 240, 138, 1)
    when :palette
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(8 + ox, 8 + oy, 253, 224, 71, 255) } }
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(w - 9 + ox, 8 + oy, 56, 189, 248, 255) } }
      (-2..2).each { |ox| (-2..2).each { |oy| set_px.call(mid + ox, h - 9 + oy, 255, 255, 255, 255) } }
    when :serial
      draw_line.call(8, 6, 8, h - 7, 255, 255, 255, t)
      draw_line.call(w - 9, 6, w - 9, h - 7, 255, 255, 255, t)
      draw_line.call(5, 9, w - 6, 9, 253, 224, 71, t)
      draw_line.call(5, h - 10, w - 6, h - 10, 253, 224, 71, t)
    when :unique
      draw_line.call(6, 8, mid + 2, 8, 255, 255, 255, t)
      draw_line.call(6, 8, 6, h - 6, 255, 255, 255, t)
      draw_line.call(mid - 2, 6, w - 6, 6, 253, 224, 71, t)
      draw_line.call(w - 6, 6, w - 6, h - 8, 253, 224, 71, t)
    when :translate
      draw_line.call(6, 7, w - 7, 7, 255, 255, 255, t)
      draw_line.call(mid, 7, mid, h - 7, 255, 255, 255, t)
      draw_line.call(7, h - 7, w - 8, 11, 253, 224, 71, t)
    when :report
      draw_line.call(7, 5, w - 8, 5, 255, 255, 255, t)
      draw_line.call(7, 5, 7, h - 6, 255, 255, 255, t)
      draw_line.call(w - 8, 5, w - 8, h - 6, 255, 255, 255, t)
      draw_line.call(7, h - 6, w - 8, h - 6, 255, 255, 255, t)
      draw_line.call(10, 10, w - 11, 10, 253, 224, 71, 1)
      draw_line.call(10, mid, w - 11, mid, 253, 224, 71, 1)
    when :pricing
      draw_line.call(mid, 5, mid, h - 5, 253, 224, 71, t)
      draw_line.call(8, 8, w - 9, 8, 255, 255, 255, t)
      draw_line.call(8, mid, w - 9, mid, 255, 255, 255, t)
      draw_line.call(8, h - 9, w - 9, h - 9, 255, 255, 255, t)
    end

    raw_bytes = buf.pack('C*')
    write_rgba_png(path, w, h, raw_bytes)
    path
  rescue
    nil
  end

  # ============================================================================
  #  مشغل الأوامر الموحد (dispatch_core_action)
  # ============================================================================
  def self.dispatch_core_action(action_id)
    case action_id.to_s.strip
    when 'open_library'
      open_dola_dialog if respond_to?(:open_dola_dialog)
    when 'component_options'
      open_unit_options_dialog
    when 'wood_grain_show_all', 'wood_grain_all_z'
      DolaWoodGrainManager.toggle_show_all_grain_indicators!
    when 'wood_grain_single_tool'
      DolaWoodGrainManager.activate_single_part_grain_tool
    when 'rotate90'
      activate_rotate_tool
    when 'flip_lr'
      activate_flip_lr_tool
    when 'snap_side'
      activate_click_side_snap_tool
    when 'classic_door'
      open_door_style_dialog
    when 'hand_groove'
      open_led_groove_dialog
    when 'kitchen_materials'
      open_kitchen_materials_tool
    when 'serial_tool'
      open_serial_numbering_dialog
    when 'unique'
      MHDESIGN_UNIQUIFY.run_uniquify
    when 'component_translator'
      run_arabic_part_translator
    when 'report'
      open_units_report_dialog
    when 'pricing_launcher'
      open_pricing_studio_dialog
    when 'draw_walls'
      DolaWallDrawer.activate_tool
    else
      UI.messagebox("الأداة غير معروفة: #{action_id}")
    end
  rescue => e
    UI.messagebox("حدث خطأ أثناء تشغيل الأداة:\n#{e.message}")
  end

  # ============================================================================
  #  الوضع الأول: الشريط الجانبي العائم (Floating Slider - HtmlDialog)
  #  بأيقونات فيكتور SVG ملونة ومميزة لكل أداة على حدة
  # ============================================================================
  @floating_slider_dlg = nil
  @slider_collapsed = false

  def self.open_floating_slider
    if @floating_slider_dlg && @floating_slider_dlg.visible?
      @floating_slider_dlg.bring_to_front rescue nil
      return true
    end

    @slider_collapsed = (Sketchup.read_default(PREF_NS, 'slider_collapsed', '0').to_s == '1')
    init_w = @slider_collapsed ? 82 : 235
    init_h = 700

    @floating_slider_dlg = UI::HtmlDialog.new({
      :dialog_title    => 'شريط أدوات مكتبة محمد عادل',
      :preferences_key => 'DolaFloatingSliderBar_v3',
      :scrollable      => false,
      :resizable       => true,
      :width           => init_w,
      :height          => init_h,
      :left            => 18,
      :top             => 90,
      :style           => UI::HtmlDialog::STYLE_UTILITY
    })

    tools_json = CORE_TOOLS_SPEC.to_json

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; user-select: none; }
          html, body {
            margin: 0; padding: 0;
            width: 100%; height: 100%;
            font-family: 'Tajawal', Tahoma, sans-serif;
            background: linear-gradient(180deg, #1e1b4b 0%, #0f172a 100%);
            color: #f8fafc;
            overflow: hidden;
          }
          .slider-shell {
            display: flex;
            flex-direction: column;
            height: 100vh;
            padding: 8px 7px;
            gap: 6px;
            border: 1px solid rgba(56, 189, 248, 0.25);
          }
          .brand-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            background: rgba(15, 23, 42, 0.82);
            border: 1px solid rgba(251, 191, 36, 0.38);
            border-radius: 11px;
            padding: 6px 8px;
            gap: 6px;
            box-shadow: 0 4px 14px rgba(0, 0, 0, 0.35);
          }
          .brand-title {
            font-size: 12px;
            font-weight: 800;
            color: #fbbf24;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          .collapse-btn {
            background: rgba(56, 189, 248, 0.16);
            border: 1px solid rgba(56, 189, 248, 0.45);
            color: #38bdf8;
            border-radius: 8px;
            width: 28px;
            height: 26px;
            cursor: pointer;
            font-weight: 800;
            font-size: 13px;
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
            transition: all 0.18s ease;
          }
          .collapse-btn:hover {
            background: #38bdf8;
            color: #0f172a;
          }
          .open-lib-btn {
            background: linear-gradient(135deg, #0284c7 0%, #0369a1 100%);
            border: 1px solid rgba(56, 189, 248, 0.65);
            color: #ffffff;
            border-radius: 11px;
            padding: 7px 10px;
            cursor: pointer;
            font-family: 'Tajawal', sans-serif;
            font-weight: 800;
            font-size: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            box-shadow: 0 4px 14px rgba(2, 132, 199, 0.4);
            transition: all 0.18s ease;
          }
          .open-lib-btn:hover {
            filter: brightness(1.12);
            transform: translateY(-1px);
          }
          .open-lib-btn svg {
            width: 20px;
            height: 20px;
            flex-shrink: 0;
          }
          .tools-scroll {
            flex: 1;
            overflow-y: auto;
            overflow-x: hidden;
            display: flex;
            flex-direction: column;
            gap: 5px;
            padding-left: 2px;
          }
          .tools-scroll::-webkit-scrollbar { width: 4px; }
          .tools-scroll::-webkit-scrollbar-thumb {
            background: rgba(56, 189, 248, 0.35);
            border-radius: 99px;
          }
          .group-divider {
            font-size: 10px;
            font-weight: 700;
            color: #94a3b8;
            padding: 4px 6px 1px;
            border-top: 1px solid rgba(255, 255, 255, 0.08);
            margin-top: 2px;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          .tool-btn {
            display: flex;
            align-items: center;
            gap: 9px;
            width: 100%;
            padding: 6px 8px;
            border-radius: 11px;
            background: rgba(30, 41, 59, 0.82);
            border: 1px solid rgba(255, 255, 255, 0.11);
            color: #f8fafc;
            cursor: pointer;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 700;
            text-align: right;
            transition: all 0.16s ease;
          }
          .tool-btn:hover {
            background: rgba(30, 58, 138, 0.45);
            border-color: rgba(56, 189, 248, 0.7);
            transform: translateY(-1px);
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.32);
          }
          .tool-icon {
            width: 32px;
            height: 32px;
            border-radius: 9px;
            border: 1px solid rgba(255, 255, 255, 0.28);
            display: flex;
            align-items: center;
            justify-content: center;
            flex-shrink: 0;
            box-shadow: 0 3px 8px rgba(0, 0, 0, 0.35), inset 0 1px 1px rgba(255, 255, 255, 0.25);
          }
          .tool-icon svg {
            width: 22px;
            height: 22px;
            display: block;
          }
          .tool-label {
            flex: 1;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          .footer-bar {
            display: flex;
            gap: 5px;
            padding-top: 4px;
            border-top: 1px solid rgba(255, 255, 255, 0.1);
          }
          .mode-switch {
            flex: 1;
            background: rgba(251, 191, 36, 0.14);
            border: 1px solid rgba(251, 191, 36, 0.4);
            color: #fbbf24;
            border-radius: 8px;
            padding: 5px 6px;
            font-family: 'Tajawal', sans-serif;
            font-size: 10.5px;
            font-weight: 700;
            cursor: pointer;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          .mode-switch:hover {
            background: #fbbf24;
            color: #0f172a;
          }

          body.collapsed .brand-title,
          body.collapsed .tool-label,
          body.collapsed .group-divider,
          body.collapsed .open-lib-text,
          body.collapsed .mode-switch-text {
            display: none !important;
          }
          body.collapsed .brand-header {
            justify-content: center;
            padding: 5px;
          }
          body.collapsed .tool-btn {
            justify-content: center;
            padding: 5px;
          }
          body.collapsed .open-lib-btn {
            padding: 7px;
          }
        </style>
      </head>
      <body class="#{@slider_collapsed ? 'collapsed' : ''}" oncontextmenu="return false;">
        <div class="slider-shell">
          <div class="brand-header">
            <span class="brand-title">✨ أدوات محمد عادل</span>
            <button class="collapse-btn" id="collapseBtn" onclick="toggleSliderCollapse()" title="طي / توسيع الشريط الجانبي">
              #{@slider_collapsed ? '⟪' : '⟫'}
            </button>
          </div>

          <button class="open-lib-btn" onclick="runTool('open_library')" title="فتح معرض مكتبة محمد عادل 3D">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round">
              <path d="M3 10l9-7 9 7v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="rgba(255,255,255,0.2)"/>
              <polyline points="9 21 9 13 15 13 15 21" stroke="#fde047"/>
            </svg>
            <span class="open-lib-text">معرض المكتبة 3D</span>
          </button>

          <div class="tools-scroll" id="toolsContainer"></div>

          <div class="footer-bar">
            <button class="mode-switch" onclick="switchToToolbar()" title="التحويل إلى شريط أدوات سكتش أب (Toolbar)">
              <span>🧰</span>
              <span class="mode-switch-text">تحويل لـ Toolbar</span>
            </button>
          </div>
        </div>

        <script>
          const TOOLS = #{tools_json};
          const GROUP_LABELS = {
            walls: 'الحوائط والغرفة',
            main: 'التحكم الأساسي بالوحدة',
            grain: 'ثمرة الخشب والـ CutList',
            transform: 'الحركة والمحاذاة',
            kitchen: 'تفاصيل وخامات المطبخ',
            utility: 'الترقيم والترجمة',
            reports: 'التقارير والتسعير'
          };

          function renderTools() {
            const container = document.getElementById('toolsContainer');
            let html = '';
            let lastGroup = '';
            TOOLS.forEach(t => {
              if (t.group !== lastGroup && GROUP_LABELS[t.group]) {
                html += `<div class="group-divider">${GROUP_LABELS[t.group]}</div>`;
                lastGroup = t.group;
              }
              const bgStyle = t.bg_grad ? `background:${t.bg_grad};` : '';
              html += `
                <button class="tool-btn" onclick="runTool('${t.id}')" title="${t.tooltip}">
                  <span class="tool-icon" style="${bgStyle}">${t.svg || ''}</span>
                  <span class="tool-label">${t.title}</span>
                </button>
              `;
            });
            container.innerHTML = html;
          }

          function runTool(id) {
            if (window.sketchup && window.sketchup.run_tool) {
              window.sketchup.run_tool(id);
            }
          }

          function toggleSliderCollapse() {
            const isCollapsed = document.body.classList.toggle('collapsed');
            document.getElementById('collapseBtn').textContent = isCollapsed ? '⟪' : '⟫';
            if (window.sketchup && window.sketchup.set_slider_collapsed) {
              window.sketchup.set_slider_collapsed(isCollapsed ? '1' : '0');
            }
          }

          function switchToToolbar() {
            if (window.sketchup && window.sketchup.switch_to_toolbar) {
              window.sketchup.switch_to_toolbar();
            }
          }

          renderTools();
        </script>
      </body>
      </html>
    HTML

    @floating_slider_dlg.set_html(html)

    @floating_slider_dlg.add_action_callback('run_tool') do |_ctx, tool_id|
      dispatch_core_action(tool_id)
    end

    @floating_slider_dlg.add_action_callback('set_slider_collapsed') do |_ctx, state|
      @slider_collapsed = (state.to_s == '1')
      Sketchup.write_default(PREF_NS, 'slider_collapsed', @slider_collapsed ? '1' : '0') rescue nil
      begin
        _, cur_h = @floating_slider_dlg.get_size
        cur_h = 700 if cur_h.to_i < 300
        @floating_slider_dlg.set_size(@slider_collapsed ? 82 : 235, cur_h.to_i)
      rescue
      end
    end

    @floating_slider_dlg.add_action_callback('switch_to_toolbar') do |_ctx|
      set_bar_mode('toolbar')
    end

    @floating_slider_dlg.show
    true
  rescue => e
    puts "Error opening floating slider: #{e.message}"
    false
  end

  def self.close_floating_slider
    if @floating_slider_dlg
      @floating_slider_dlg.close rescue nil
      @floating_slider_dlg = nil
    end
    true
  end

  # ============================================================================
  #  الوضع الثاني: شريط أدوات سكتش أب الأصلي (Native UI::Toolbar)
  # ============================================================================
  @native_tools_toolbar = nil

  def self.ensure_native_toolbar
    return @native_tools_toolbar if @native_tools_toolbar

    tb = UI::Toolbar.new('مكتبة محمد عادل - الأدوات')
    icon_dir = toolbar_icons_dir

    lib_cmd = UI::Command.new('معرض مكتبة محمد عادل') { dispatch_core_action('open_library') }
    lib_cmd.tooltip = 'فتح معرض مكتبة محمد عادل الثلاثي الأبعاد'
    lib_cmd.status_bar_text = 'فتح معرض مكتبة محمد عادل (المطابخ والدريسنج)'
    lib_s = generate_tool_icon_png(File.join(icon_dir, 'lib_16.png'), 16, [2, 132, 199], :library)
    lib_l = generate_tool_icon_png(File.join(icon_dir, 'lib_24.png'), 24, [2, 132, 199], :library)
    lib_cmd.small_icon = lib_s if lib_s
    lib_cmd.large_icon = lib_l if lib_l
    tb.add_item(lib_cmd)
    tb.add_separator

    last_group = CORE_TOOLS_SPEC.first[:group]
    CORE_TOOLS_SPEC.each do |spec|
      if spec[:group] != last_group
        tb.add_separator
        last_group = spec[:group]
      end

      cmd = UI::Command.new(spec[:title]) { dispatch_core_action(spec[:id]) }
      cmd.tooltip = spec[:tooltip]
      cmd.status_bar_text = spec[:tooltip]

      s_path = generate_tool_icon_png(File.join(icon_dir, "#{spec[:id]}_16.png"), 16, spec[:rgb], spec[:symbol])
      l_path = generate_tool_icon_png(File.join(icon_dir, "#{spec[:id]}_24.png"), 24, spec[:rgb], spec[:symbol])
      cmd.small_icon = s_path if s_path
      cmd.large_icon = l_path if l_path
      tb.add_item(cmd)
    end

    @native_tools_toolbar = tb
  rescue => e
    puts "Error creating native toolbar: #{e.message}"
    nil
  end

  def self.show_native_toolbar
    tb = ensure_native_toolbar
    tb.show if tb
    true
  rescue
    false
  end

  def self.hide_native_toolbar
    @native_tools_toolbar.hide if @native_tools_toolbar
    true
  rescue
    false
  end

  # ============================================================================
  #  التبديل المرن بين أوضاع الشريط (Slider / Toolbar / Both / Hide)
  # ============================================================================
  def self.apply_bar_preferences
    unless saved_bar_visible?
      close_floating_slider
      hide_native_toolbar
      return true
    end

    case saved_bar_mode
    when 'toolbar'
      close_floating_slider
      show_native_toolbar
    when 'both'
      open_floating_slider
      show_native_toolbar
    else
      hide_native_toolbar
      open_floating_slider
    end
    true
  end

  def self.show_tools_bar
    save_bar_visible(true)
    apply_bar_preferences
  end

  def self.hide_tools_bar
    save_bar_visible(false)
    close_floating_slider
    hide_native_toolbar
  end

  def self.set_bar_mode(mode)
    save_bar_mode(mode)
    save_bar_visible(true)
    apply_bar_preferences
  end

  # ============================================================================
  #  نظام التحكم المتكامل والآمن في «ثمرة الخشب» (Wood Grain)
  #  • لا يلمس محاور أو معادلات الـ Dynamic Component نهائياً (صفر تفكيك للوحدات)
  #  • يبدل حصرياً بين أكبر مقاسين في القطعة (الطول ⇄ العرض) ويستبعد السماكة (1.8 سم / 0.6 سم)
  #  • يدعم التبديل الذكي (Toggle) في زر اتجاه Z: ضغطة توحّد وضغطة ثانية ترجّع للأصل
  # ============================================================================
  module DolaWoodGrainManager
    extend self

    AXIS_NAMES = ['x', 'y', 'z'].freeze
    @show_all_grain_active = false

    def show_all_grain_active?
      @show_all_grain_active == true
    end

    def set_show_all_grain_active(flag)
      @show_all_grain_active = (flag == true)
    end

    NON_WOOD_KEYWORDS = [
      'مفصلة', 'مقبض', 'رجول', 'رجل', 'مجرى', 'سحاب', 'زجاج', 'ازاز', 'إزاز',
      'glass', 'hinge', 'handle', 'leg', 'runner', 'رخام', 'جرانيت', 'كوريان',
      'marble', 'granite', 'ستانلس', 'حوض', 'بوتاجاز', 'فرن', 'ثلاجة', 'شفاط',
      'غسالة', 'ميكروويف', 'led', 'ليد', 'مسمار', 'كويلا', 'إليتا', 'اليتا',
      'wire', 'basket', 'سلة', 'مصفاة', 'ترولي'
    ].freeze

    WOOD_GRAIN_KEYWORDS = [
      'خشابي', 'خشب', 'ثمرة', 'سمرة', 'قشرة', 'ارو', 'أرو', 'زان', 'بلوط',
      'جوز', 'تك', 'شيبرد', 'ميلامين', 'hpl', 'إتش بي إل', 'اتش بي ال',
      'وشين', 'ضهر خشابي', 'ظهر خشابي', 'wood', 'oak', 'walnut', 'veneer',
      'grain', 'maple', 'cherry', 'beech', 'ash', 'pine', 'mahogany', 'teak',
      'بني', 'بيج خشبي', 'دافئ'
    ].freeze

    BACK_PANEL_KEYWORDS = [
      'ضهر', 'ظهر', 'ظهريه', 'ظهرية', 'ضهريه', 'ضهرية', 'back'
    ].freeze

    def ents_of(entity)
      return entity.definition.entities if entity.is_a?(Sketchup::ComponentInstance)
      return entity.entities if entity.is_a?(Sketchup::Group)
      nil
    rescue
      nil
    end

    def entity_display_name(entity)
      return '' unless entity && entity.valid?
      dc_name = entity.get_attribute('dynamic_attributes', '_name', nil) ||
                entity.get_attribute('dynamic_attributes', 'name', nil)
      if entity.is_a?(Sketchup::ComponentInstance)
        n = entity.name.to_s.strip
        n = entity.definition.name.to_s.strip if n.empty?
        n = dc_name.to_s.strip if n.empty?
        n
      elsif entity.is_a?(Sketchup::Group)
        n = entity.name.to_s.strip
        n = dc_name.to_s.strip if n.empty?
        n.empty? ? 'قطعة خشبية' : n
      else
        ''
      end
    rescue
      'قطعة خشبية'
    end

    def back_panel_board?(entity, info = nil)
      nm = entity_display_name(entity).downcase
      if entity.is_a?(Sketchup::ComponentInstance) && entity.definition
        nm += ' ' + entity.definition.name.to_s.downcase
      end
      return true if BACK_PANEL_KEYWORDS.any? { |w| nm.include?(w) }
      return true if info && info[:thick_cm].to_f > 0.1 && info[:thick_cm].to_f <= 1.0 && info[:is_vertical_board]
      false
    rescue
      false
    end

    def non_wood_accessory?(entity, mat = nil)
      name_str = entity_display_name(entity).downcase
      if entity.is_a?(Sketchup::ComponentInstance)
        name_str += ' ' + entity.definition.name.to_s.downcase
      end
      mat_str = mat ? (mat.display_name.to_s + ' ' + mat.name.to_s).downcase : ''
      combined = "#{name_str} #{mat_str}"
      NON_WOOD_KEYWORDS.any? { |kw| combined.include?(kw) }
    rescue
      false
    end

    def effective_material_for(entity, inherited_mat = nil)
      return nil unless entity && entity.valid?
      mat = entity.material || inherited_mat
      ents = ents_of(entity)
      if ents
        faces = ents.grep(Sketchup::Face)
        textured_face = faces.find { |f| (f.material && f.material.texture) || (f.back_material && f.back_material.texture) }
        if textured_face
          return (textured_face.material && textured_face.material.texture) ? textured_face.material : textured_face.back_material
        end
        colored_face = faces.find { |f| f.material || f.back_material }
        mat ||= (colored_face.material || colored_face.back_material) if colored_face
      end
      mat
    rescue
      inherited_mat
    end

    def has_wood_grain_material?(entity, inherited_mat = nil)
      return false unless entity && entity.valid?
      mat = effective_material_for(entity, inherited_mat)
      return false if non_wood_accessory?(entity, mat)

      if mat && mat.get_attribute(GRAIN_DICT, 'grained_override', nil) == 'false'
        return false
      end
      if mat && mat.get_attribute(GRAIN_DICT, 'grained_override', nil) == 'true'
        return true
      end

      return true if mat && mat.texture

      mat_name = mat ? "#{mat.display_name} #{mat.name}".downcase : ''
      part_name = entity_display_name(entity).downcase
      combined = "#{mat_name} #{part_name}"
      return true if WOOD_GRAIN_KEYWORDS.any? { |kw| combined.include?(kw) }

      saved = entity.get_attribute(GRAIN_DICT, 'grain_dir', nil)
      return true unless saved.to_s.empty?

      false
    rescue
      false
    end

    def ensure_procedural_wood_texture!(mat)
      return nil unless mat
      return mat if mat.texture
      return mat unless defined?(Zlib)

      c = mat.color || Sketchup::Color.new(185, 135, 88)
      base_r = c.red
      base_g = c.green
      base_b = c.blue
      if base_r > 240 && base_g > 240 && base_b > 240
        base_r, base_g, base_b = 194, 148, 102
      end

      tex_name = "dola_wood_#{base_r}_#{base_g}_#{base_b}.png"
      tex_path = File.join(DolaSmartLibraryPlugin.toolbar_icons_dir, tex_name)
      unless File.exist?(tex_path) && File.size(tex_path) > 100
        w = 64
        h = 64
        buf = Array.new(w * h * 4, 0)
        (0...h).each do |y|
          stripe = Math.sin(y * 0.45) * 14.0 + Math.cos(y * 1.15) * 7.0
          (0...w).each do |x|
            fine = Math.sin((y * 2.2) + (x * 0.08)) * 5.0
            delta = (stripe + fine).round
            r = [[base_r + delta, 15].max, 250].min
            g = [[base_g + delta, 15].max, 250].min
            b = [[base_b + delta, 15].max, 250].min
            idx = (y * w + x) * 4
            buf[idx]     = r
            buf[idx + 1] = g
            buf[idx + 2] = b
            buf[idx + 3] = 255
          end
        end
        DolaSmartLibraryPlugin.write_rgba_png(tex_path, w, h, buf.pack('C*'))
      end

      if File.exist?(tex_path)
        mat.texture = tex_path
        mat.texture.size = [40.cm, 40.cm] rescue nil
      end
      mat
    rescue
      mat
    end

    def leaf_wooden_board?(entity)
      return false unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
      return false unless entity.valid?
      ents = ents_of(entity)
      return false unless ents
      faces = ents.grep(Sketchup::Face)
      return false if faces.empty?

      bb = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition.bounds : entity.bounds
      dims = [bb.width.to_f, bb.height.to_f, bb.depth.to_f].sort
      return false if dims[2] < 0.2.cm
      true
    rescue
      false
    end

    def collect_wooden_boards(roots, require_texture_only = true)
      results = []

      walk = lambda do |ent, parent_tr, inh_mat, root_unit|
        next unless ent && ent.valid?
        next if ent.hidden? || (ent.layer && !ent.layer.visible?)
        next unless ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)

        cur_mat = ent.material || inh_mat
        world_tr = parent_tr * ent.transformation
        ents = ents_of(ent)
        next unless ents

        sub_containers = ents.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
        faces = ents.grep(Sketchup::Face)

        if !faces.empty? && leaf_wooden_board?(ent) && !non_wood_accessory?(ent, cur_mat)
          if !require_texture_only || has_wood_grain_material?(ent, cur_mat)
            results << {
              :entity        => ent,
              :root_unit     => root_unit,
              :parent_tr     => parent_tr,
              :world_tr      => world_tr,
              :inherited_mat => cur_mat
            }
          end
        end

        sub_containers.each do |child|
          walk.call(child, world_tr, cur_mat, root_unit)
        end
      end

      Array(roots).each do |r|
        walk.call(r, Geom::Transformation.new, nil, r)
      end
      results
    end

    # إرجاع المحاور المحلية للقطعة إلى وضع الـ Dynamic Component الأصلي قبل أي فحص أو Redraw
    def undo_part_ocl_axis_transform!(entity)
      return false unless entity && entity.valid?
      arr = entity.get_attribute(GRAIN_DICT, 'applied_m_axes', nil)
      if arr.nil? && entity.is_a?(Sketchup::ComponentInstance) && entity.definition
        arr = entity.definition.get_attribute(GRAIN_DICT, 'applied_m_axes', nil)
      end
      return false unless arr.is_a?(Array) && arr.length == 16

      m_axes = Geom::Transformation.new(arr.map(&:to_f))
      ents = ents_of(entity)
      return false unless ents

      ents.transform_entities(m_axes, ents.to_a)
      entity.transformation = entity.transformation * m_axes.inverse

      entity.delete_attribute(GRAIN_DICT, 'applied_m_axes') rescue nil
      if entity.is_a?(Sketchup::ComponentInstance) && entity.definition
        entity.definition.delete_attribute(GRAIN_DICT, 'applied_m_axes') rescue nil
      end
      true
    rescue => e
      puts "undo_part_ocl_axis_transform! error: #{e.message}"
      false
    end

    # تطبيق تدوير محاور متوافق 100% مع OpenCutList بين أكبر مقاسين فقط بدون تحريك القطعة في 3D:
    # المحور الأحمر المحلي (X = 0) = اتجاه الثمرة المختار (أحد أكبر مقاسين)
    # المحور الأخضر المحلي (Y = 1) = المقاس الكبير الثاني (العرض)
    # المحور الأزرق المحلي (Z = 2) = السماكة الثابتة دائماً (أصغر مقاس: 1.8 سم أو 0.6 سم)
    def apply_part_ocl_axis_transform!(entity, desired_grain_idx, desired_cross_idx, thick_idx)
      return false unless entity && entity.valid?

      if entity.is_a?(Sketchup::ComponentInstance) && entity.definition.count_used_instances > 1
        entity.make_unique
      elsif entity.is_a?(Sketchup::Group)
        entity.make_unique rescue nil
      end

      ents = ents_of(entity)
      return false unless ents

      g_idx = desired_grain_idx.to_i % 3
      c_idx = desired_cross_idx.to_i % 3
      t_idx = thick_idx.to_i % 3

      if g_idx == 0 && c_idx == 1 && t_idx == 2
        entity.delete_attribute(GRAIN_DICT, 'applied_m_axes') rescue nil
        if entity.is_a?(Sketchup::ComponentInstance) && entity.definition
          entity.definition.delete_attribute(GRAIN_DICT, 'applied_m_axes') rescue nil
        end
        return true
      end

      basis = [
        Geom::Vector3d.new(1.0, 0.0, 0.0),
        Geom::Vector3d.new(0.0, 1.0, 0.0),
        Geom::Vector3d.new(0.0, 0.0, 1.0)
      ]

      vx = basis[g_idx]
      vy = basis[c_idx]
      vz = vx.cross(vy)

      bb = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition.bounds : entity.bounds
      min_coords = [bb.min.x.to_f, bb.min.y.to_f, bb.min.z.to_f]
      max_coords = [bb.max.x.to_f, bb.max.y.to_f, bb.max.z.to_f]

      orig_coords = [0.0, 0.0, 0.0]
      if vz.dot(basis[t_idx]) < 0.0
        orig_coords[t_idx] = min_coords[t_idx] + max_coords[t_idx]
      end
      origin_pt = Geom::Point3d.new(orig_coords[0], orig_coords[1], orig_coords[2])

      m_axes = Geom::Transformation.axes(origin_pt, vx, vy, vz)
      m_perm = m_axes.inverse

      ents.transform_entities(m_perm, ents.to_a)
      entity.transformation = entity.transformation * m_axes

      arr = m_axes.to_a
      entity.set_attribute(GRAIN_DICT, 'applied_m_axes', arr)
      if entity.is_a?(Sketchup::ComponentInstance) && entity.definition
        entity.definition.set_attribute(GRAIN_DICT, 'applied_m_axes', arr)
      end
      true
    rescue => e
      puts "apply_part_ocl_axis_transform! error: #{e.message}"
      false
    end

    # فحص هندسة اللوح واتجاه الثمرة الحالي بدقة تامة:
    # يستبعد دائماً أصغر مقاس (السماكة 1.8 سم أو 0.6 سم) ويبدل فقط بين أكبر مقاسين!
    def inspect_part_grain(entity, parent_tr = Geom::Transformation.new, inherited_mat = nil, root_unit = nil)
      return nil unless leaf_wooden_board?(entity)
      world_tr = parent_tr * entity.transformation
      bb = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition.bounds : entity.bounds

      local_dims = [bb.width.to_f, bb.height.to_f, bb.depth.to_f]
      world_vecs = [world_tr.xaxis, world_tr.yaxis, world_tr.zaxis]
      scales     = world_vecs.map { |v| v.length > 1e-6 ? v.length : 1.0 }
      world_dims = [local_dims[0] * scales[0], local_dims[1] * scales[1], local_dims[2] * scales[2]]

      # ترتيب المحاور الـ 3 تصاعدياً حسب المقاس الفعلي في المشهد:
      # أصغر محور دائماً هو السماكة (1.8 سم أو 0.6 سم) ومستحيل يدخل في تبديل الثمرة!
      sorted_axes = [0, 1, 2].sort_by { |i| world_dims[i] }
      thick_idx   = sorted_axes[0]
      # أكبر مقاسين فقط هما محورا مستوى اللوح (الطول والعرض)
      i1 = sorted_axes[1]
      i2 = sorted_axes[2]

      unit_vecs = world_vecs.map do |v|
        c = v.clone
        c.normalize! rescue nil
        c
      end

      u1 = unit_vecs[i1]
      u2 = unit_vecs[i2]

      if u1.z.abs >= 0.45 || u2.z.abs >= 0.45
        vert_idx  = (u1.z.abs >= u2.z.abs) ? i1 : i2
        horiz_idx = (vert_idx == i1) ? i2 : i1
        is_vertical_board = true
      else
        ref_x = parent_tr.xaxis.clone
        ref_x = Geom::Vector3d.new(1.0, 0.0, 0.0) if ref_x.length < 1e-6
        ref_x.normalize! rescue nil
        d1 = u1.dot(ref_x).abs
        d2 = u2.dot(ref_x).abs
        vert_idx  = (d1 >= d2) ? i1 : i2
        horiz_idx = (vert_idx == i1) ? i2 : i1
        is_vertical_board = false
      end

      defn = entity.is_a?(Sketchup::ComponentInstance) ? entity.definition : nil
      saved_dir = entity.get_attribute(GRAIN_DICT, 'grain_dir', nil)
      saved_dir = defn.get_attribute(GRAIN_DICT, 'grain_dir', nil) if saved_dir.to_s.empty? && defn

      ocl_locked = defn ? (defn.get_attribute(OCL_DICT, 'orientation_locked_on_axis', false) == true) : false

      active_grain_idx =
        if saved_dir.to_s == 'vertical_z'
          vert_idx
        elsif saved_dir.to_s == 'horizontal_x'
          horiz_idx
        elsif ocl_locked && [vert_idx, horiz_idx].include?(0)
          0
        else
          (world_dims[vert_idx] >= world_dims[horiz_idx]) ? vert_idx : horiz_idx
        end

      active_cross_idx = (active_grain_idx == vert_idx) ? horiz_idx : vert_idx
      current_mode     = (active_grain_idx == vert_idx) ? :vertical_z : :horizontal_x

      grain_len_cm = (world_dims[active_grain_idx] * 2.54).round(1)
      cross_wid_cm = (world_dims[active_cross_idx] * 2.54).round(1)
      thick_cm     = (world_dims[thick_idx] * 2.54).round(2)
      thick_mm     = (world_dims[thick_idx] * 25.4).round(1)

      mat = effective_material_for(entity, inherited_mat)
      mat_title = mat ? mat.display_name.to_s : 'خشب'

      pts_local = [
        Geom::Point3d.new(bb.min.x, bb.min.y, bb.min.z),
        Geom::Point3d.new(bb.max.x, bb.min.y, bb.min.z),
        Geom::Point3d.new(bb.max.x, bb.max.y, bb.min.z),
        Geom::Point3d.new(bb.min.x, bb.max.y, bb.min.z),
        Geom::Point3d.new(bb.min.x, bb.min.y, bb.max.z),
        Geom::Point3d.new(bb.max.x, bb.min.y, bb.max.z),
        Geom::Point3d.new(bb.max.x, bb.max.y, bb.max.z),
        Geom::Point3d.new(bb.min.x, bb.max.y, bb.max.z)
      ]
      world_corners = pts_local.map { |pt| world_tr * pt }
      world_center  = world_tr * bb.center
      max_world_z   = world_corners.map(&:z).max.to_f
      unit_top_z    = (root_unit && root_unit.valid?) ? [root_unit.bounds.max.z.to_f, max_world_z].max : max_world_z

      mode_label =
        if is_vertical_board
          current_mode == :vertical_z ? 'بالطول ↕ (Z)' : 'بالعرض ↔ (X)'
        else
          current_mode == :vertical_z ? 'مع العرض ↔' : 'مع العمق ↕'
        end

      info_hash = {
        :entity            => entity,
        :root_unit         => root_unit,
        :parent_tr         => parent_tr,
        :inherited_mat     => inherited_mat,
        :name              => entity_display_name(entity),
        :material_name     => mat_title,
        :has_grain         => has_wood_grain_material?(entity, inherited_mat),
        :is_vertical_board => is_vertical_board,
        :mode              => current_mode,
        :mode_label        => mode_label,
        :vert_idx          => vert_idx,
        :horiz_idx         => horiz_idx,
        :thick_idx         => thick_idx,
        :grain_idx         => active_grain_idx,
        :cross_idx         => active_cross_idx,
        :grain_len_cm      => grain_len_cm,
        :cross_wid_cm      => cross_wid_cm,
        :thick_cm          => thick_cm,
        :thick_mm          => thick_mm,
        :grain_vec         => unit_vecs[active_grain_idx],
        :cross_vec         => unit_vecs[active_cross_idx],
        :thick_vec         => unit_vecs[thick_idx],
        :grain_world_dim   => world_dims[active_grain_idx],
        :cross_world_dim   => world_dims[active_cross_idx],
        :thick_world_dim   => world_dims[thick_idx],
        :world_corners     => world_corners,
        :world_center      => world_center,
        :max_world_z       => max_world_z,
        :unit_top_z        => unit_top_z
      }
      info_hash[:is_back_panel] = back_panel_board?(entity, info_hash)
      if info_hash[:is_back_panel]
        # نقطة العلامة العلوية للضهر فوق الوحدة مباشرة حتى يراها المصمم من الأمام بوضوح
        top_anchor = Geom::Point3d.new(world_center.x, world_center.y, max_world_z)
        badge_pt   = Geom::Point3d.new(world_center.x, world_center.y, unit_top_z + 10.cm)
        info_hash[:back_top_anchor] = top_anchor
        info_hash[:back_badge_pt]   = badge_pt
      end
      info_hash
    rescue
      nil
    end

    def snapshot_original_grain_state!(entity, info)
      return unless entity && entity.valid? && info
      return if entity.get_attribute(GRAIN_DICT, 'orig_snapshot_saved', false) == true

      entity.set_attribute(GRAIN_DICT, 'orig_snapshot_saved', true)
      entity.set_attribute(GRAIN_DICT, 'orig_grain_idx', info[:grain_idx])
      entity.set_attribute(GRAIN_DICT, 'orig_cross_idx', info[:cross_idx])
      entity.set_attribute(GRAIN_DICT, 'orig_thick_idx', info[:thick_idx])
      entity.set_attribute(GRAIN_DICT, 'orig_grain_dir', entity.get_attribute(GRAIN_DICT, 'grain_dir', '').to_s)

      if entity.is_a?(Sketchup::ComponentInstance) && entity.definition
        defn = entity.definition
        has_ocl = !defn.attribute_dictionary(OCL_DICT, false).nil?
        entity.set_attribute(GRAIN_DICT, 'orig_has_ocl', has_ocl)
        if has_ocl
          entity.set_attribute(GRAIN_DICT, 'orig_ocl_auto_orient', defn.get_attribute(OCL_DICT, 'auto_orient', nil))
          entity.set_attribute(GRAIN_DICT, 'orig_ocl_locked', defn.get_attribute(OCL_DICT, 'orientation_locked_on_axis', nil))
        end
      end
    rescue
    end

    # تبديل اتجاه الثمرة بين أكبر مقاسين فقط في OpenCutList بدون تغيير أي خامة أو تفكيك الوحدة
    def set_part_grain!(entity, target_mode, parent_tr = Geom::Transformation.new, inherited_mat = nil, save_snapshot = false)
      return false unless entity && entity.valid?

      undo_part_ocl_axis_transform!(entity)

      info = inspect_part_grain(entity, parent_tr, inherited_mat)
      return false unless info

      snapshot_original_grain_state!(entity, info) if save_snapshot

      target_mode = (target_mode.to_sym == :horizontal_x) ? :horizontal_x : :vertical_z

      desired_grain_idx = (target_mode == :vertical_z) ? info[:vert_idx] : info[:horiz_idx]
      desired_cross_idx = (target_mode == :vertical_z) ? info[:horiz_idx] : info[:vert_idx]
      thick_idx         = info[:thick_idx]

      # تبديل المحورين المحليين X و Y بين أكبر مقاسين فقط وتثبيت Z على السماكة (1.8 سم أو 0.6 سم)
      apply_part_ocl_axis_transform!(entity, desired_grain_idx, desired_cross_idx, thick_idx)

      ents = ents_of(entity)
      return false unless ents

      if entity.is_a?(Sketchup::ComponentInstance) && entity.definition
        defn = entity.definition
        defn.set_attribute(OCL_DICT, 'auto_orient', false)
        defn.set_attribute(OCL_DICT, 'orientation_locked_on_axis', true)
        defn.delete_attribute(OCL_DICT, 'axes_order') rescue nil
        defn.set_attribute(GRAIN_DICT, 'grain_dir', target_mode.to_s)
        defn.set_attribute(GRAIN_DICT, 'grain_axis_idx', 0)
      end

      entity.set_attribute(GRAIN_DICT, 'grain_dir', target_mode.to_s)
      entity.set_attribute(GRAIN_DICT, 'grain_axis_idx', 0)

      # لا نغيّر لون أو ننشئ خامة جديدة نهائياً حتى لا تتغير خامة الكونتر الأبيض في OpenCutList!
      # فقط إذا كانت الخامة تحتوي أصلاً على Texture خشبي نضبط اتجاه الـ UV الخاص بها.
      mat = effective_material_for(entity, inherited_mat)
      if mat && mat.texture
        align_faces_uv_along_local_axis!(ents, mat, 0, 1)
      end

      true
    rescue => e
      puts "WoodGrain set_part_grain! error: #{e.message}"
      false
    end

    def align_faces_uv_along_local_axis!(ents, fallback_mat, grain_axis_idx, cross_axis_idx)
      local_axes = [
        Geom::Vector3d.new(1, 0, 0),
        Geom::Vector3d.new(0, 1, 0),
        Geom::Vector3d.new(0, 0, 1)
      ]
      primary_vec   = local_axes[grain_axis_idx.to_i % 3]
      secondary_vec = local_axes[cross_axis_idx.to_i % 3]

      ents.grep(Sketchup::Face).each do |face|
        next unless face && face.valid?
        f_mat = (face.material && face.material.texture) ? face.material : fallback_mat
        next unless f_mat && f_mat.texture

        n = face.normal
        u_dir = primary_vec.clone
        if u_dir.parallel?(n)
          u_dir = secondary_vec.clone
        end
        v_dir = n.cross(u_dir)
        next if v_dir.length < 1e-6
        v_dir.normalize!
        u_dir = v_dir.cross(n)
        next if u_dir.length < 1e-6
        u_dir.normalize!

        tw = [f_mat.texture.width.to_f, 1.0].max
        th = [f_mat.texture.height.to_f, 1.0].max

        p0 = face.vertices.first.position
        p1 = p0.offset(u_dir, tw)
        p2 = p0.offset(v_dir, th)

        pts = [
          p0, Geom::Point3d.new(0, 0, 0),
          p1, Geom::Point3d.new(1, 0, 0),
          p2, Geom::Point3d.new(0, 1, 0)
        ]

        begin
          face.position_material(f_mat, pts, true)
        rescue
        end
        if face.back_material && face.back_material.texture
          begin
            face.position_material(face.back_material, pts, false)
          rescue
          end
        end
      end
    end

    def restore_dc_axes_before_redraw!(root_unit)
      saved_states = []
      return saved_states unless root_unit && root_unit.valid?
      boards = collect_wooden_boards([root_unit], false)
      boards.each do |b|
        ent = b[:entity]
        next unless ent && ent.valid?
        dir = ent.get_attribute(GRAIN_DICT, 'grain_dir', nil)
        if dir.to_s.empty? && ent.is_a?(Sketchup::ComponentInstance) && ent.definition
          dir = ent.definition.get_attribute(GRAIN_DICT, 'grain_dir', nil)
        end
        has_m = !ent.get_attribute(GRAIN_DICT, 'applied_m_axes', nil).nil?
        if !dir.to_s.empty? || has_m
          undo_part_ocl_axis_transform!(ent)
          saved_states << { :entity => ent, :dir => dir.to_s } unless dir.to_s.empty?
        end
      end
      saved_states
    rescue
      saved_states
    end

    def reapply_grain_after_redraw!(root_unit, _saved_states = [])
      return unless root_unit && root_unit.valid?
      boards = collect_wooden_boards([root_unit], false)
      boards.each do |b|
        ent = b[:entity]
        next unless ent && ent.valid?
        dir = ent.get_attribute(GRAIN_DICT, 'grain_dir', nil)
        if dir.to_s.empty? && ent.is_a?(Sketchup::ComponentInstance) && ent.definition
          dir = ent.definition.get_attribute(GRAIN_DICT, 'grain_dir', nil)
        end
        next if dir.to_s.empty?
        set_part_grain!(ent, dir.to_sym, b[:parent_tr], b[:inherited_mat], false)
      end
    rescue
    end

    # زر «بيان اتجاه الثمرة»: يظهر/يخفي اتجاه الثمرة لجميع قطع الوحدة شاملة علامة الضهر فوق الوحدة
    def toggle_show_all_grain_indicators!
      @show_all_grain_active = !@show_all_grain_active
      if @show_all_grain_active
        Sketchup.active_model.select_tool(DolaWoodGrainInspectorTool.new(true))
      else
        Sketchup.active_model.select_tool(nil)
        Sketchup.active_model.active_view.invalidate
      end
      DolaSmartLibraryPlugin.refresh_unit_options_dialog_if_open rescue nil
      @show_all_grain_active
    end

    def align_all_wood_grain_to_z!
      toggle_show_all_grain_indicators!
    end

    def activate_single_part_grain_tool
      Sketchup.active_model.select_tool(DolaWoodGrainInspectorTool.new(@show_all_grain_active))
    end
  end

  # ============================================================================
  #  أداة «بيان اتجاه الثمرة + قلب ثمرة القطعة يدوياً بين أكبر مقاسين»
  #  • تعرض علامات وأسهم اتجاه الثمرة لكل قطع الوحدة في وقت واحد
  #  • ترفع علامة وسهم «الضهريات» فوق الوحدة من أعلى حتى تُرى من الأمام بوضوح
  #  • تسمح بالضغط على أي قطعة (أو على علامة الضهر العلوية) لقلب ثمرتها فوراً في OpenCutList
  # ============================================================================
  class DolaWoodGrainInspectorTool
    def initialize(show_all_mode = false)
      @show_all_mode     = show_all_mode
      @all_boards_info   = []
      @hovered_info      = nil
      @hovered_parent_tr = nil
      @hovered_inh_mat   = nil
      @mouse_x           = 0
      @mouse_y           = 0
    end

    def activate
      @hovered_info = nil
      DolaWoodGrainManager.set_show_all_grain_active(@show_all_mode)
      rebuild_all_boards_cache
      if @show_all_mode
        Sketchup.status_text = '👁️🪵 بيان اتجاه الثمرة مفعّل (علامة الضهريات معروضة فوق الوحدة): اضغط كليك شمال على أي قطعة أو على علامة الضهر العلوية لقلب ثمرتها بين أكبر مقاسين.'
      else
        Sketchup.status_text = '🪵 أداة قلب ثمرة القطعة يدوياً: حرّك الماوس فوق أي قطعة (أو علامة الضهر فوق الوحدة) واضغط كليك شمال للتبديل بين أكبر مقاسين في OpenCutList.'
      end
      DolaSmartLibraryPlugin.refresh_unit_options_dialog_if_open rescue nil
      Sketchup.active_model.active_view.invalidate
    end

    def deactivate(view)
      @hovered_info = nil
      DolaWoodGrainManager.set_show_all_grain_active(false)
      DolaSmartLibraryPlugin.refresh_unit_options_dialog_if_open rescue nil
      view.invalidate if view
    end

    def onCancel(_reason, view)
      @hovered_info = nil
      DolaWoodGrainManager.set_show_all_grain_active(false)
      Sketchup.active_model.select_tool(nil)
      DolaSmartLibraryPlugin.refresh_unit_options_dialog_if_open rescue nil
      view.invalidate if view
    end

    def rebuild_all_boards_cache
      @all_boards_info = []
      model = Sketchup.active_model
      roots = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
      roots = model.active_entities.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) } if roots.empty?

      raw_boards = DolaWoodGrainManager.collect_wooden_boards(roots, false)
      raw_boards.each do |b|
        info = DolaWoodGrainManager.inspect_part_grain(b[:entity], b[:parent_tr], b[:inherited_mat], b[:root_unit])
        @all_boards_info << info if info
      end
    rescue
      @all_boards_info = []
    end

    # التقاط القطعة إما من علامة الضهر المرفوعة فوق الوحدة أو من المجسم ثلاثي الأبعاد مباشرة
    def pick_board_at(view, x, y)
      # 1. فحص ما إذا كان الماوس فوق علامة الضهر العلوية المرسومة فوق الوحدة
      if @all_boards_info && !@all_boards_info.empty?
        @all_boards_info.each do |info|
          next unless info[:is_back_panel] && info[:back_badge_pt]
          scr = view.screen_coords(info[:back_badge_pt]) rescue nil
          next unless scr
          if (scr.x - x).abs <= 58 && (scr.y - y).abs <= 26
            return [info, info[:parent_tr], info[:inherited_mat]]
          end
        end
      end

      # 2. التقاط القطعة هندسياً تحت الماوس
      ph = view.pick_helper
      ph.do_pick(x, y)
      return nil if ph.count <= 0

      best_candidate = nil

      (0...ph.count).each do |idx|
        path = ph.path_at(idx)
        next unless path && !path.empty?

        containers = path.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
        next if containers.empty?
        root_unit = containers.first

        containers.reverse_each do |target|
          next unless DolaWoodGrainManager.leaf_wooden_board?(target)

          parent_tr = Geom::Transformation.new
          inh_mat = nil
          containers.each do |anc|
            break if anc == target
            parent_tr = parent_tr * anc.transformation
            inh_mat = anc.material if anc.material
          end

          next if DolaWoodGrainManager.non_wood_accessory?(target, target.material || inh_mat)

          info = DolaWoodGrainManager.inspect_part_grain(target, parent_tr, inh_mat, root_unit)
          next unless info

          if info[:has_grain]
            return [info, parent_tr, inh_mat]
          else
            best_candidate ||= [info, parent_tr, inh_mat]
          end
        end
      end

      best_candidate
    rescue
      nil
    end

    def onMouseMove(_flags, x, y, view)
      @mouse_x = x
      @mouse_y = y
      picked = pick_board_at(view, x, y)
      if picked
        @hovered_info, @hovered_parent_tr, @hovered_inh_mat = picked
        Sketchup.status_text = "🪵 القطعة: #{@hovered_info[:name]} | الثمرة: #{@hovered_info[:mode_label]} | أكبر مقاسين: طول #{@hovered_info[:grain_len_cm]} سم × عرض #{@hovered_info[:cross_wid_cm]} سم (السُمك الثابت: #{@hovered_info[:thick_cm]} سم) — كليك شمال لقلب الثمرة"
      else
        @hovered_info = nil
        Sketchup.status_text = '🪵 حرّك الماوس فوق أي قطعة خشبية أو فوق علامة الضهر العلوية واضغط كليك شمال لقلب الثمرة بين أكبر مقاسين.'
      end
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      picked = pick_board_at(view, x, y)
      return unless picked

      info, parent_tr, inh_mat = picked
      ent = info[:entity]
      return unless ent && ent.valid?

      new_mode = (info[:mode] == :vertical_z) ? :horizontal_x : :vertical_z

      model = Sketchup.active_model
      model.start_operation('قلب اتجاه ثمرة القطعة الخشبية - مكتبة محمد عادل', true)
      begin
        DolaWoodGrainManager.set_part_grain!(ent, new_mode, parent_tr, inh_mat, true)
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("تعذر قلب الثمرة:\n#{e.message}")
        return
      end

      rebuild_all_boards_cache
      updated = DolaWoodGrainManager.inspect_part_grain(ent, parent_tr, inh_mat, info[:root_unit])
      if updated
        @hovered_info = updated
        Sketchup.status_text = "✨ تم تبديل الثمرة في OpenCutList بين أكبر مقاسين: طول #{updated[:grain_len_cm]} سم × عرض #{updated[:cross_wid_cm]} سم (السُمك الثابت: #{updated[:thick_cm]} سم)"
      end
      view.invalidate
    end

    def draw_double_arrow_3d(view, center_pt, dir_vec, ortho_vec, half_len, head_len, color, line_w = 3)
      return unless center_pt && dir_vec && ortho_vec
      p_start = center_pt.offset(dir_vec, -half_len)
      p_end   = center_pt.offset(dir_vec,  half_len)

      view.line_width = line_w
      view.drawing_color = color
      view.draw(GL_LINES, [p_start, p_end])

      h1_a = p_end.offset(dir_vec, -head_len).offset(ortho_vec,  head_len * 0.55)
      h1_b = p_end.offset(dir_vec, -head_len).offset(ortho_vec, -head_len * 0.55)
      view.draw(GL_LINES, [p_end, h1_a, p_end, h1_b])

      h2_a = p_start.offset(dir_vec, head_len).offset(ortho_vec,  head_len * 0.55)
      h2_b = p_start.offset(dir_vec, head_len).offset(ortho_vec, -head_len * 0.55)
      view.draw(GL_LINES, [p_start, h2_a, p_start, h2_b])
    end

    def draw_board_indicator(view, info, is_hovered = false)
      return unless info
      is_vert = (info[:mode] == :vertical_z)
      arrow_color = is_vert ? Sketchup::Color.new(16, 185, 129) : Sketchup::Color.new(245, 158, 11)
      box_color   = is_vert ? Sketchup::Color.new(56, 189, 248) : Sketchup::Color.new(251, 191, 36)

      if is_hovered && info[:world_corners] && info[:world_corners].length == 8
        corners = info[:world_corners]
        edges = [0,1, 1,2, 2,3, 3,0, 4,5, 5,6, 6,7, 7,4, 0,4, 1,5, 2,6, 3,7]
        view.line_width = 3
        view.drawing_color = box_color
        view.draw(GL_LINES, edges.map { |i| corners[i] })
      end

      center    = info[:world_center]
      grain_vec = info[:grain_vec]
      cross_vec = info[:cross_vec]
      thick_vec = info[:thick_vec]

      if center && grain_vec && cross_vec && thick_vec
        cam_eye = view.camera.eye
        to_cam  = cam_eye - center
        sign    = (to_cam.dot(thick_vec) >= 0) ? 1.0 : -1.0
        half_t  = (info[:thick_world_dim].to_f * 0.5) + 0.35.cm
        face_center = center.offset(thick_vec, sign * half_t)

        arrow_half_len = [[info[:grain_world_dim].to_f * 0.28, 2.2.cm].max, 18.cm].min
        head_size      = [arrow_half_len * 0.25, 1.0.cm].max

        draw_double_arrow_3d(view, face_center, grain_vec, cross_vec, arrow_half_len, head_size, arrow_color, is_hovered ? 4 : 3)

        if is_hovered
          cross_spread = [[info[:cross_world_dim].to_f * 0.22, 1.5.cm].max, 12.cm].min
          [-1, 1].each do |slot|
            side_pt = face_center.offset(cross_vec, slot * cross_spread)
            draw_double_arrow_3d(view, side_pt, grain_vec, cross_vec, arrow_half_len * 0.85, head_size * 0.85, arrow_color, 3)
          end
        end

        if @show_all_mode && !info[:is_back_panel]
          scr_pt = view.screen_coords(face_center) rescue nil
          if scr_pt
            short_tag = is_vert ? '↕ طول' : '↔ عرض'
            begin
              view.draw_text(Geom::Point3d.new(scr_pt.x - 18, scr_pt.y - 8, 0), short_tag, :size => 10, :bold => true, :color => arrow_color)
            rescue
              view.draw_text(Geom::Point3d.new(scr_pt.x - 18, scr_pt.y - 8, 0), short_tag) rescue nil
            end
          end
        end
      end

      # إذا كانت القطعة «ضهرية» (Back Panel) نرفع لها خط إرشادي وعلامة وسهم واضح فوق الوحدة من أعلى!
      if info[:is_back_panel] && info[:back_top_anchor] && info[:back_badge_pt]
        anchor_pt = info[:back_top_anchor]
        badge_pt  = info[:back_badge_pt]
        back_color = is_vert ? Sketchup::Color.new(52, 211, 153) : Sketchup::Color.new(251, 191, 36)

        view.line_width = is_hovered ? 4 : 2
        view.line_stipple = '-'
        view.drawing_color = back_color
        view.draw(GL_LINES, [anchor_pt, badge_pt])
        view.line_stipple = ''

        # رسم سهم اتجاه ثمرة الضهر فوق الوحدة مباشرة
        if grain_vec && cross_vec
          draw_double_arrow_3d(view, badge_pt, grain_vec, cross_vec, 7.5.cm, 2.0.cm, back_color, is_hovered ? 5 : 4)
        end

        scr_badge = view.screen_coords(badge_pt) rescue nil
        if scr_badge
          b_txt = "⬆️ ضهر (#{info[:name]}): #{is_vert ? 'رأسي ↕' : 'أفقي ↔'} (#{info[:grain_len_cm]}×#{info[:cross_wid_cm]} سم)"
          pt_txt = Geom::Point3d.new(scr_badge.x - 65, scr_badge.y - 26, 0)
          begin
            view.draw_text(pt_txt, b_txt, :size => 11, :bold => true, :color => back_color)
          rescue
            view.draw_text(pt_txt, b_txt) rescue nil
          end
        end
      end
    end

    def draw(view)
      if @show_all_mode && @all_boards_info && !@all_boards_info.empty?
        @all_boards_info.each do |b_info|
          next if @hovered_info && b_info[:entity] == @hovered_info[:entity]
          draw_board_indicator(view, b_info, false)
        end
      elsif @all_boards_info && !@all_boards_info.empty?
        # حتى في الوضع اليدوي الفردي نُبقي علامة الضهريات ظاهرة فوق الوحدة لتسهيل رؤيتها وتعديلها من الأمام
        @all_boards_info.each do |b_info|
          next unless b_info[:is_back_panel]
          next if @hovered_info && b_info[:entity] == @hovered_info[:entity]
          draw_board_indicator(view, b_info, false)
        end
      end

      if @hovered_info
        draw_board_indicator(view, @hovered_info, true)
        is_vert = (@hovered_info[:mode] == :vertical_z)
        box_color = is_vert ? Sketchup::Color.new(56, 189, 248) : Sketchup::Color.new(251, 191, 36)
        screen_pt = Geom::Point3d.new(@mouse_x + 18, @mouse_y - 28, 0)
        label_txt = "🪵 #{@hovered_info[:name]} | الثمرة: #{@hovered_info[:mode_label]}\n📐 الطول: #{@hovered_info[:grain_len_cm]} سم × العرض: #{@hovered_info[:cross_wid_cm]} سم (السُمك الثابت: #{@hovered_info[:thick_cm]} سم)"
        begin
          view.draw_text(screen_pt, label_txt, :size => 11, :bold => true, :color => box_color)
        rescue
          view.draw_text(screen_pt, label_txt) rescue nil
        end
      end
    rescue
    end
  end

  # ============================================================================
  #  نظام «الخلع والعمود (خلعة الحائط والركنة)» لوحدات المطبخ
  #  • يحافظ 100% على خامة الكونتر الأبيض الأصلية في OpenCutList بدون إنشاء خامة جديدة
  #  • يخصم مقاس الخلع من لوح الضهر أو يقسمه لجزئين (يمين ويسار العمود) بدقة
  #  • يستكمل الضهر خلف الخلع بنفس قيمة سقوط المحفار (أو بداية من الخلف)
  #  • يدعم الخلع الخلفي والخلع الجانبي لوحدات الركنة (الزاوية)
  #  • يصغّر عمق الأدراج تلقائياً بقيمة بروز الخلع
  # ============================================================================
  def self.read_unit_wall_relief_config(unit, unit_width_cm)
    default_cfg = {
      'enabled'        => 'no',
      'wall_width'     => [unit_width_cm.to_f, 200.0].max.round(1),
      'placement'      => 'right',
      'cabinet_offset' => 0.0,
      'columns'        => []
    }
    return default_cfg unless unit && unit.valid?
    raw = unit.get_attribute(RELIEF_DICT, 'config_json', nil)
    return default_cfg if raw.to_s.strip.empty?
    parsed = JSON.parse(raw.to_s) rescue nil
    return default_cfg unless parsed.is_a?(Hash)
    default_cfg.merge(parsed)
  rescue
    default_cfg
  end

  # استخراج مواصفات خامة الشاسيه الداخلي (الكونتر الأبيض) مطابقة 100% للجنب/القاعدة بدون إنشاء أي خامة جديدة
  def self.find_kitchen_carcass_material_spec(unit)
    spec = { :inst_mat => nil, :front_mat => nil, :back_mat => nil }
    return spec unless unit && unit.valid? && unit.is_a?(Sketchup::ComponentInstance)

    exclude_part_words = %w[ضلفة ضلفه ضلف باب ابواب وش درج ادراج رجل رجول وزر وزرة مقبض مفصلة زجاج ازاز ليد door front drawer leg plinth foot handle hinge glass led]
    exclude_mat_words  = %w[hpl ضلف واجه زجاج glass ستانلس رخام]
    prefer_part_words  = %w[جنب قاعدة قاع رف برنيطة برنيطه مرايا شاسيه شاسية قاطوع side bottom base shelf top rail carcass]

    best_spec = nil
    fallback_spec = nil

    read_spec_from = lambda do |ent, inh_mat|
      inst_m = ent.material || inh_mat
      f_mat  = nil
      b_mat  = nil
      ents = DolaWoodGrainManager.ents_of(ent)
      if ents
        face = ents.grep(Sketchup::Face).find { |fc| fc.material || fc.back_material }
        if face
          f_mat = face.material
          b_mat = face.back_material
        end
      end
      check_m = inst_m || f_mat || b_mat
      return nil unless check_m
      mname = "#{check_m.display_name} #{check_m.name}".downcase
      return nil if exclude_mat_words.any? { |w| mname.include?(w) }
      { :inst_mat => inst_m, :front_mat => f_mat, :back_mat => b_mat }
    end

    walk = lambda do |container, inh_mat|
      ents = DolaWoodGrainManager.ents_of(container)
      return unless ents
      ents.each do |e|
        next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        next unless e.valid?
        next if e.hidden?
        next if e.get_attribute(RELIEF_DICT, 'is_relief_cladding', false) == true

        pname = DolaWoodGrainManager.entity_display_name(e).downcase
        pname += ' ' + e.definition.name.to_s.downcase if e.is_a?(Sketchup::ComponentInstance)
        next if exclude_part_words.any? { |w| pname.include?(w) }

        is_back = pname.include?('ضهر') || pname.include?('ظهر') || pname.include?('back')
        cur_inh = e.material || inh_mat

        unless is_back
          cand = read_spec_from.call(e, inh_mat)
          if cand
            if prefer_part_words.any? { |w| pname.include?(w) }
              best_spec ||= cand
            else
              fallback_spec ||= cand
            end
          end
        end

        walk.call(e, cur_inh) if best_spec.nil?
      end
    end

    walk.call(unit, nil)
    best_spec || fallback_spec || spec
  rescue
    spec
  end

  # تحليل شامل لشاسيه وحدة المطبخ (المستقيمة والركنة) والضهريات وسقوط المحفار والأدراج
  def self.analyze_kitchen_unit_carcass(unit, payload = nil)
    defn = unit.definition
    lbb  = defn.bounds

    tr = unit.transformation
    sx = tr.xaxis.length > 1e-6 ? tr.xaxis.length : 1.0
    sy = tr.yaxis.length > 1e-6 ? tr.yaxis.length : 1.0
    sz = tr.zaxis.length > 1e-6 ? tr.zaxis.length : 1.0

    total_h_local = lbb.depth.to_f
    leg_words    = %w[رجل رجول وزر وزرة ارجل أرجل كعب leg legs plinth foot feet]
    door_words   = %w[ضلفة ضلفه ضلف باب ابواب وش مقبض مفصلة door doors front handle hinge]
    drawer_words = %w[درج ادراج أدراج مجرى سحاب drawer slide runner]
    back_words   = %w[ضهر ظهر ظهريه ظهرية ضهريه ضهرية back]
    side_words   = %w[جنب قاطوع side]
    base_words   = %w[قاعدة قاع برنيطة برنيطه مرايا سقف bottom base top rail]

    carcass_parts  = []
    side_parts     = []
    back_parts_x   = [] # ضهر خلفي يمتد على محور X (رفيع في Y)
    back_parts_y   = [] # ضهر جانبي في وحدات الركنة يمتد على محور Y (رفيع في X)
    drawer_parts   = []
    leg_max_z_list = []

    defn.entities.each do |e|
      next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
      next unless e.valid?
      next if e.hidden?
      next if e.get_attribute(RELIEF_DICT, 'is_relief_cladding', false) == true

      pname = DolaWoodGrainManager.entity_display_name(e).downcase
      pname += ' ' + e.definition.name.to_s.downcase if e.is_a?(Sketchup::ComponentInstance)

      eb = e.bounds
      next if eb.empty?

      if leg_words.any? { |w| pname.include?(w) }
        leg_max_z_list << eb.max.z.to_f if (eb.max.z.to_f - lbb.min.z.to_f) < total_h_local * 0.45
        next
      end

      is_door_front = door_words.any? { |w| pname.include?(w) } && !pname.include?('جنب درج') && !pname.include?('قاع درج') && !pname.include?('ضهر درج') && !pname.include?('ظهر درج')
      if drawer_words.any? { |w| pname.include?(w) } && !is_door_front
        drawer_parts << e
        next
      end
      next if is_door_front

      if (eb.max.z.to_f - lbb.min.z.to_f) < total_h_local * 0.26 && (eb.depth.to_f * sz) < 22.cm
        leg_max_z_list << eb.max.z.to_f
        next
      end

      w_x = eb.width.to_f * sx
      w_y = eb.height.to_f * sy
      w_z = eb.depth.to_f * sz

      is_named_back = back_words.any? { |w| pname.include?(w) } && !pname.include?('درج')
      is_thin_y_back = (w_y <= 2.2.cm && w_x >= (lbb.width.to_f * sx * 0.45) && w_z >= (total_h_local * sz * 0.40) && (lbb.max.y.to_f - eb.max.y.to_f).abs * sy < 8.cm)
      is_thin_x_back = (w_x <= 1.2.cm && w_y >= (lbb.height.to_f * sy * 0.45) && w_z >= (total_h_local * sz * 0.40))

      if is_named_back || is_thin_y_back || is_thin_x_back
        if w_y <= w_x
          back_parts_x << e
        else
          back_parts_y << e
        end
        carcass_parts << e
      elsif side_words.any? { |w| pname.include?(w) } || (w_x <= 3.0.cm && w_y >= (lbb.height.to_f * sy * 0.40) && w_z >= (total_h_local * sz * 0.40))
        side_parts << e
        carcass_parts << e
      elsif base_words.any? { |w| pname.include?(w) } || (w_z <= 3.0.cm && w_x >= (lbb.width.to_f * sx * 0.45))
        carcass_parts << e
      elsif w_z >= (total_h_local * sz * 0.40)
        carcass_parts << e
      end
    end

    z_ref_parts = !side_parts.empty? ? side_parts : carcass_parts
    if !z_ref_parts.empty?
      cz_min = z_ref_parts.map { |p| p.bounds.min.z.to_f }.min
      cz_max = z_ref_parts.map { |p| p.bounds.max.z.to_f }.max
    else
      cz_min = lbb.min.z.to_f
      cz_max = lbb.max.z.to_f
    end

    if !leg_max_z_list.empty?
      detected_leg_top = leg_max_z_list.max
      cz_min = [cz_min, detected_leg_top].max if (detected_leg_top - lbb.min.z.to_f) < total_h_local * 0.40
    end

    if payload && payload[:fields].is_a?(Array)
      leg_field = payload[:fields].find do |f|
        lbl = f['label'].to_s
        (lbl.include?('رجل') || lbl.include?('رجول') || lbl.include?('وزر')) && f['is_length']
      end
      if leg_field && leg_field['value'].to_f > 0.5
        leg_h_local = leg_field['value'].to_f.cm / sz
        if leg_h_local < total_h_local * 0.45
          cz_min = [cz_min, lbb.min.z.to_f + leg_h_local].max
        end
      end
    end

    non_back_carcass = carcass_parts - back_parts_x - back_parts_y
    ref_xy_parts = !non_back_carcass.empty? ? non_back_carcass : carcass_parts
    if !ref_xy_parts.empty?
      cx_min = ref_xy_parts.map { |p| p.bounds.min.x.to_f }.min
      cx_max = ref_xy_parts.map { |p| p.bounds.max.x.to_f }.max
      cy_min = ref_xy_parts.map { |p| p.bounds.min.y.to_f }.min
      cy_max = ref_xy_parts.map { |p| p.bounds.max.y.to_f }.max
    else
      cx_min = lbb.min.x.to_f
      cx_max = lbb.max.x.to_f
      cy_min = lbb.min.y.to_f
      cy_max = lbb.max.y.to_f
    end

    {
      :cx_min       => cx_min,
      :cx_max       => cx_max,
      :cy_min       => cy_min,
      :cy_max       => cy_max,
      :cz_min       => cz_min,
      :cz_max       => cz_max,
      :sx           => sx,
      :sy           => sy,
      :sz           => sz,
      :back_parts_x => back_parts_x,
      :back_parts_y => back_parts_y,
      :side_parts   => side_parts,
      :drawer_parts => drawer_parts
    }
  end

  # إنشاء لوح خشبي مستقل بنفس خامة الكونتر الأصلية 100% (بدون إنشاء خامة جديدة في OpenCutList)
  # مع ضبط اتجاه السحب للأعلى (+Z) وضبط محاور OpenCutList (X=الطول، Y=العرض، Z=التخانة)
  def self.create_kitchen_relief_board_instance!(parent_defn, board_name, x0, x1, y0, y1, z0, z1, mat_spec, parent_tr = Geom::Transformation.new)
    xa, xb = [x0.to_f, x1.to_f].minmax
    ya, yb = [y0.to_f, y1.to_f].minmax
    za, zb = [z0.to_f, z1.to_f].minmax
    w_x = xb - xa
    w_y = yb - ya
    w_z = zb - za
    return nil if w_x <= 1e-4 || w_y <= 1e-4 || w_z <= 1e-4

    model = Sketchup.active_model
    cdef = model.definitions.add(board_name)

    pts = [
      Geom::Point3d.new(0.0, 0.0, 0.0),
      Geom::Point3d.new(w_x, 0.0, 0.0),
      Geom::Point3d.new(w_x, w_y, 0.0),
      Geom::Point3d.new(0.0, w_y, 0.0)
    ]
    face = cdef.entities.add_face(pts)
    if face
      face.reverse! if face.normal.z < 0.0
      face.pushpull(w_z)
    end

    inst_Mat  = mat_spec.is_a?(Hash) ? mat_spec[:inst_mat]  : mat_spec
    front_Mat = mat_spec.is_a?(Hash) ? mat_spec[:front_mat] : nil
    back_Mat  = mat_spec.is_a?(Hash) ? mat_spec[:back_mat]  : nil

    if front_Mat || back_Mat
      cdef.entities.grep(Sketchup::Face).each do |fc|
        fc.material      = front_Mat if front_Mat
        fc.back_material = back_Mat  if back_Mat
      end
    end

    inst_tr = Geom::Transformation.translation(Geom::Point3d.new(xa, ya, za))
    inst = parent_defn.entities.add_instance(cdef, inst_tr)
    inst.name = board_name
    inst.material = inst_Mat if inst_Mat
    inst.set_attribute(RELIEF_DICT, 'is_relief_cladding', true)
    cdef.set_attribute(RELIEF_DICT, 'is_relief_cladding', true)

    # ضبط محاور اللوح في OpenCutList بدون تغيير الخامة إطلاقاً
    DolaWoodGrainManager.set_part_grain!(inst, :vertical_z, parent_tr, inst_Mat, false) rescue nil

    inst
  rescue => e
    puts "create_kitchen_relief_board_instance! error: #{e.message}"
    nil
  end

  # طرح فترات الأعمدة [nx0..nx1] من مدى لوح الضهر الأصلي [bx0..bx1] لإنتاج القطع المتبقية (قطعة أو قطعتين أو أكثر)
  def self.subtract_intervals_1d(base_start, base_end, cuts, min_len = 0.5)
    segments = [[base_start.to_f, base_end.to_f]]
    Array(cuts).each do |cut|
      c0, c1 = cut[0].to_f, cut[1].to_f
      next if c1 <= c0
      next_segs = []
      segments.each do |seg|
        s0, s1 = seg[0], seg[1]
        if c1 <= s0 || c0 >= s1
          next_segs << [s0, s1]
        else
          next_segs << [s0, c0] if (c0 - s0) > min_len
          next_segs << [c1, s1] if (s1 - c1) > min_len
        end
      end
      segments = next_segs
    end
    segments
  end

  # استخراج مواصفات خامة لوح معين كما هي بالضبط
  def self.extract_exact_part_mat_spec(part, fallback_spec)
    return fallback_spec unless part && part.valid?
    f_mat = nil
    b_mat = nil
    ents = DolaWoodGrainManager.ents_of(part)
    if ents
      fc = ents.grep(Sketchup::Face).find { |f| f.material || f.back_material }
      if fc
        f_mat = fc.material
        b_mat = fc.back_material
      end
    end
    if part.material || f_mat || b_mat
      { :inst_mat => part.material, :front_mat => f_mat, :back_mat => b_mat }
    else
      fallback_spec
    end
  rescue
    fallback_spec
  end

  # تخصيم أو تقسيم ألواح الضهر (الخلفي على محور X أو الجانبي لوحدات الركنة على محور Y)
  # مع قراءة قيمة سقوط المحفار وتخانة الضهر الأصلي لإرجاعها لاستكمال الضهر خلف الخلع!
  def self.process_back_panels_and_groove_for_notches!(parent_defn, c_info, x_notches, y_notches, carcass_mat_spec, unit_tr)
    sx = c_info[:sx]
    sy = c_info[:sy]
    by1 = c_info[:cy_max]
    bx1_carcass = c_info[:cx_max]
    bx0_carcass = c_info[:cx_min]

    default_back_info = {
      :groove_drop_y => 0.0,
      :thick_y       => 1.8.cm / sy,
      :groove_drop_x => 0.0,
      :thick_x       => 1.8.cm / sx,
      :z0            => c_info[:cz_min],
      :z1            => c_info[:cz_max],
      :mat_spec      => carcass_mat_spec
    }

    # 1. معالجة الضهر الخلفي الممتد على محور X
    if !c_info[:back_parts_x].empty? && !x_notches.empty?
      c_info[:back_parts_x].each do |bp|
        next unless bp && bp.valid?
        bb = bp.bounds
        next if bb.empty?

        bx0 = bb.min.x.to_f
        bx1 = bb.max.x.to_f
        bp_y0 = bb.min.y.to_f
        bp_y1 = bb.max.y.to_f
        bz0 = bb.min.z.to_f
        bz1 = bb.max.z.to_f

        t_y = [bp_y1 - bp_y0, 0.4.cm / sy].max
        g_drop_y = [by1 - bp_y1, 0.0].max
        bp_mat_spec = extract_exact_part_mat_spec(bp, carcass_mat_spec)

        default_back_info[:groove_drop_y] = g_drop_y
        default_back_info[:thick_y]       = t_y
        default_back_info[:z0]            = bz0
        default_back_info[:z1]            = bz1
        default_back_info[:mat_spec]      = bp_mat_spec

        cuts = x_notches.map { |n| [n[:nx0], n[:nx1]] }
        overlapping = cuts.any? { |c| [bx1, c[1]].min - [bx0, c[0]].max > (0.2.cm / sx) }
        next unless overlapping

        # إخفاء الضهر الأصلي بدون تشويه معادلاته وإنشاء أجزاء الضهر المخصومة أو المقسومة لجزئين بنفس سقوط المحفار
        bp.hidden = true
        bp.set_attribute(RELIEF_DICT, 'hidden_by_relief', true)

        rem_segs = subtract_intervals_1d(bx0, bx1, cuts, 1.0.cm / sx)
        rem_segs.each_with_index do |seg, s_idx|
          part_title = rem_segs.length > 1 ? "ضهر الوحدة بعد الخلع (جزء #{s_idx + 1})" : "ضهر الوحدة بعد خصم الخلع"
          create_kitchen_relief_board_instance!(
            parent_defn,
            part_title,
            seg[0], seg[1],
            bp_y0, bp_y1,
            bz0, bz1,
            bp_mat_spec,
            unit_tr
          )
        end
      end
    end

    # 2. معالجة الضهر الجانبي الممتد على محور Y (في وحدات الركنة / الزاوية)
    if !c_info[:back_parts_y].empty? && !y_notches.empty?
      c_info[:back_parts_y].each do |bp|
        next unless bp && bp.valid?
        bb = bp.bounds
        next if bb.empty?

        bp_x0 = bb.min.x.to_f
        bp_x1 = bb.max.x.to_f
        by0 = bb.min.y.to_f
        by1_bp = bb.max.y.to_f
        bz0 = bb.min.z.to_f
        bz1 = bb.max.z.to_f

        t_x = [bp_x1 - bp_x0, 0.4.cm / sx].max
        dist_right = (bx1_carcass - bp_x1).abs
        dist_left  = (bp_x0 - bx0_carcass).abs
        g_drop_x   = [dist_right, dist_left].min
        bp_mat_spec = extract_exact_part_mat_spec(bp, carcass_mat_spec)

        default_back_info[:groove_drop_x] = g_drop_x
        default_back_info[:thick_x]       = t_x

        cuts = y_notches.map { |n| [n[:ny0], n[:ny1]] }
        overlapping = cuts.any? { |c| [by1_bp, c[1]].min - [by0, c[0]].max > (0.2.cm / sy) }
        next unless overlapping

        bp.hidden = true
        bp.set_attribute(RELIEF_DICT, 'hidden_by_relief', true)

        rem_segs = subtract_intervals_1d(by0, by1_bp, cuts, 1.0.cm / sy)
        rem_segs.each_with_index do |seg, s_idx|
          part_title = rem_segs.length > 1 ? "ضهر ركنة جانبي بعد الخلع (جزء #{s_idx + 1})" : "ضهر ركنة جانبي بعد خصم الخلع"
          create_kitchen_relief_board_instance!(
            parent_defn,
            part_title,
            bp_x0, bp_x1,
            seg[0], seg[1],
            bz0, bz1,
            bp_mat_spec,
            unit_tr
          )
        end
      end
    end

    default_back_info
  end

  # تصغير عمق الأدراج تلقائياً بقيمة بروز الخلع (سواء عبر خصائص الـ DC أو تعديل شاسيه الدرج الداخلي مع الحفاظ على وش الدرج)
  def self.adjust_kitchen_drawers_for_relief!(unit, c_info, reduce_depth_cm, payload = nil)
    return if reduce_depth_cm.to_f <= 0.3
    sy = c_info[:sy]
    reduce_local_y = reduce_depth_cm.to_f.cm / sy

    # 1. إذا كان هناك حقل مباشر لعمق الدرج في خصائص الـ Dynamic Component للوحدة نعدله ونحفظ أصله
    if payload && payload[:fields].is_a?(Array)
      drawer_depth_fields = payload[:fields].select do |f|
        lbl = f['label'].to_s
        f['access'] != 'VIEW' && f['is_length'] && lbl.include?('عمق') && (lbl.include?('درج') || lbl.include?('ادراج') || lbl.include?('أدراج') || lbl.include?('مجرى'))
      end
      if !drawer_depth_fields.empty?
        saved_drawer_dc = {}
        changes = {}
        drawer_depth_fields.each do |df|
          cur_v = df['value'].to_f
          next if cur_v <= 5.0
          new_v = [cur_v - reduce_depth_cm.to_f, 15.0].max.round(1)
          saved_drawer_dc[df['key'].to_s] = cur_v.to_s
          changes[df['key'].to_s] = new_v.to_s
        end
        unless changes.empty?
          unit.set_attribute(RELIEF_DICT, 'orig_drawer_dc_json', saved_drawer_dc.to_json)
          apply_unit_dc_options_changes!(changes, false)
        end
      end
    end

    # 2. فحص وتصغير علب الأدراج الهندسية داخل تعريف الوحدة (جنبين الدرج + قاع الدرج + تقديم ضهر الدرج)
    #    مع ترك «وش الدرج» الأمامي ثابتاً في مكانه 100%!
    defn = unit.definition
    front_words = %w[وش ضلفة ضلفه باب مقبض front door face handle]
    back_words  = %w[ضهر ظهر خلف back rear]

    shrink_drawer_entity = lambda do |ent, anchor_min_y, orig_span_y|
      return unless ent && ent.valid?
      return unless ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)
      eb = ent.bounds
      return if eb.empty?

      nm = DolaWoodGrainManager.entity_display_name(ent).downcase
      nm += ' ' + ent.definition.name.to_s.downcase if ent.is_a?(Sketchup::ComponentInstance)

      # لا نلمس وش الدرج الأمامي إطلاقاً
      return if front_words.any? { |w| nm.include?(w) } && !nm.include?('جنب') && !nm.include?('قاع') && !nm.include?('ضهر') && !nm.include?('ظهر')

      ents = DolaWoodGrainManager.ents_of(ent)
      sub_containers = ents ? ents.select { |c| c.is_a?(Sketchup::ComponentInstance) || c.is_a?(Sketchup::Group) } : []

      # إذا كان هذا جروب/كمبوننت حاوي لعلبة الدرج وبداخله أجزاء فرعية، نطبّق التصغير على أجزائه الداخلية بدقة
      # حتى لا تقل تخانة ضهر الدرج أو وش الدرج عند عمل Scale!
      if !sub_containers.empty? && sub_containers.length >= 2
        ent.make_unique if ent.is_a?(Sketchup::ComponentInstance) && ent.definition.count_used_instances > 1
        c_bb = ent.is_a?(Sketchup::ComponentInstance) ? ent.definition.bounds : ent.bounds
        c_span_y = c_bb.height.to_f
        return if c_span_y <= reduce_local_y + (5.cm / sy)

        sub_containers.each do |child|
          next unless child && child.valid?
          cb = child.bounds
          next if cb.empty?
          cnm = DolaWoodGrainManager.entity_display_name(child).downcase
          cnm += ' ' + child.definition.name.to_s.downcase if child.is_a?(Sketchup::ComponentInstance)

          # استبعاد وش الدرج لو كان داخل الحاوية
          next if (front_words.any? { |w| cnm.include?(w) } || (cb.height.to_f * sy <= 2.5.cm && (cb.min.y - c_bb.min.y).abs * sy < 3.0.cm)) && !cnm.include?('جنب') && !cnm.include?('قاع')

          if child.get_attribute(RELIEF_DICT, 'orig_tr_matrix', nil).nil?
            child.set_attribute(RELIEF_DICT, 'orig_tr_matrix', child.transformation.to_a)
          end

          is_drawer_back = back_words.any? { |w| cnm.include?(w) } || (cb.height.to_f * sy <= 2.5.cm && (c_bb.max.y - cb.max.y).abs * sy < 5.0.cm)
          if is_drawer_back
            # لوح ضهر الدرج: نحركه للأمام بمقدار بروز الخلع حتى يحافظ على تخانته (1.8 سم) في OpenCutList
            shift_tr = Geom::Transformation.translation(Geom::Vector3d.new(0.0, -reduce_local_y, 0.0))
            child.transform!(shift_tr)
          elsif cb.height.to_f > reduce_local_y + (4.cm / sy)
            # جنبين الدرج وقاع الدرج والمجرى: نصغر طولها على محور Y مع تثبيت مقدمتها الأمامية
            ratio = (cb.height.to_f - reduce_local_y) / cb.height.to_f
            scale_tr = Geom::Transformation.scaling(Geom::Point3d.new(cb.min.x, cb.min.y, cb.min.z), 1.0, ratio, 1.0)
            child.transform!(scale_tr)
          end
        end
      else
        if ent.get_attribute(RELIEF_DICT, 'orig_tr_matrix', nil).nil?
          ent.set_attribute(RELIEF_DICT, 'orig_tr_matrix', ent.transformation.to_a)
        end

        is_drawer_back = back_words.any? { |w| nm.include?(w) } || (eb.height.to_f * sy <= 2.5.cm && (c_info[:cy_max] - eb.max.y).abs * sy < 12.0.cm)
        if is_drawer_back
          shift_tr = Geom::Transformation.translation(Geom::Vector3d.new(0.0, -reduce_local_y, 0.0))
          ent.transform!(shift_tr)
        elsif eb.height.to_f > reduce_local_y + (5.cm / sy)
          ratio = (eb.height.to_f - reduce_local_y) / eb.height.to_f
          scale_tr = Geom::Transformation.scaling(Geom::Point3d.new(eb.min.x, eb.min.y, eb.min.z), 1.0, ratio, 1.0)
          ent.transform!(scale_tr)
        end
      end
    end

    c_info[:drawer_parts].each do |dp|
      shrink_drawer_entity.call(dp, dp.bounds.min.y, dp.bounds.height.to_f)
    end
  rescue => e
    puts "adjust_kitchen_drawers_for_relief! error: #{e.message}"
  end

  def self.restore_nested_relief_transforms!(container)
    ents = DolaWoodGrainManager.ents_of(container)
    return unless ents
    ents.each do |e|
      next unless e && e.valid? && e.respond_to?(:get_attribute)
      if e.get_attribute(RELIEF_DICT, 'hidden_by_relief', false) == true
        e.hidden = false rescue nil
        e.delete_attribute(RELIEF_DICT, 'hidden_by_relief') rescue nil
      end
      orig_tr_arr = e.get_attribute(RELIEF_DICT, 'orig_tr_matrix', nil)
      if orig_tr_arr.is_a?(Array) && orig_tr_arr.length == 16
        e.transformation = Geom::Transformation.new(orig_tr_arr.map(&:to_f)) rescue nil
        e.delete_attribute(RELIEF_DICT, 'orig_tr_matrix') rescue nil
      end
      if e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        restore_nested_relief_transforms!(e)
      end
    end
  rescue
  end

  def self.remove_kitchen_unit_wall_relief!(unit)
    return false unless unit && unit.valid?
    model = Sketchup.active_model
    model.start_operation('إلغاء خلعة الحائط والعمود - مكتبة محمد عادل', true)
    begin
      if unit.is_a?(Sketchup::ComponentInstance) && unit.definition
        to_erase = unit.definition.entities.select do |e|
          e && e.valid? && e.respond_to?(:get_attribute) && e.get_attribute(RELIEF_DICT, 'is_relief_cladding', false) == true
        end
        to_erase.each { |e| e.erase! rescue nil }

        restore_nested_relief_transforms!(unit)
      end

      orig_drawer_dc_raw = unit.get_attribute(RELIEF_DICT, 'orig_drawer_dc_json', nil)
      if orig_drawer_dc_raw && !orig_drawer_dc_raw.to_s.empty?
        orig_drawer_dc = JSON.parse(orig_drawer_dc_raw.to_s) rescue nil
        apply_unit_dc_options_changes!(orig_drawer_dc, false) if orig_drawer_dc.is_a?(Hash) && !orig_drawer_dc.empty?
      end

      orig_depth_key = unit.get_attribute(RELIEF_DICT, 'orig_depth_key', nil)
      orig_depth_val = unit.get_attribute(RELIEF_DICT, 'orig_depth_val', nil)
      if orig_depth_key && !orig_depth_val.nil?
        apply_unit_dc_options_changes!({ orig_depth_key.to_s => orig_depth_val.to_s }, false)
      end

      shifted_vec = unit.get_attribute(RELIEF_DICT, 'shifted_world_vec', nil)
      if shifted_vec.is_a?(Array) && shifted_vec.length == 3
        inv_v = Geom::Vector3d.new(-shifted_vec[0].to_f, -shifted_vec[1].to_f, -shifted_vec[2].to_f)
        unit.transform!(Geom::Transformation.translation(inv_v)) if inv_v.length > 1e-4
      end

      unit.delete_attribute(RELIEF_DICT, 'orig_depth_key') rescue nil
      unit.delete_attribute(RELIEF_DICT, 'orig_depth_val') rescue nil
      unit.delete_attribute(RELIEF_DICT, 'orig_drawer_dc_json') rescue nil
      unit.delete_attribute(RELIEF_DICT, 'shifted_world_vec') rescue nil
      unit.set_attribute(RELIEF_DICT, 'config_json', { 'enabled' => 'no', 'columns' => [] }.to_json)

      model.commit_operation
      model.active_view.invalidate
      refresh_unit_options_dialog_if_open(unit)
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("تعذر إلغاء الخلع:\n#{e.message}")
      false
    end
  end

  def self.apply_kitchen_unit_wall_relief!(cfg_hash)
    unit = find_selected_dc_unit
    unless unit && unit.valid?
      UI.messagebox('الرجاء تحديد وحدة المطبخ أولاً.')
      return false
    end

    if unit.get_attribute(RELIEF_DICT, 'orig_depth_key', nil) ||
       unit.get_attribute(RELIEF_DICT, 'orig_drawer_dc_json', nil) ||
       (unit.is_a?(Sketchup::ComponentInstance) && unit.definition.entities.any? { |e| e.respond_to?(:get_attribute) && (e.get_attribute(RELIEF_DICT, 'is_relief_cladding', false) || e.get_attribute(RELIEF_DICT, 'hidden_by_relief', false) || !e.get_attribute(RELIEF_DICT, 'orig_tr_matrix', nil).nil?) })
      remove_kitchen_unit_wall_relief!(unit)
    end

    bb = unit.bounds
    cab_w_cm = (bb.width.to_f * 2.54).round(1)
    cab_d_cm = (bb.depth.to_f * 2.54).round(1)

    wall_w    = [cfg_hash['wall_width'].to_f, cab_w_cm].max
    place     = cfg_hash['placement'].to_s == 'right' ? 'right' : 'left'
    cab_off   = [cfg_hash['cabinet_offset'].to_f, 0.0].max
    cab_start = (place == 'right') ? [wall_w - cab_off - cab_w_cm, 0.0].max : [cab_off, [wall_w - cab_w_cm, 0.0].max].min

    cols = Array(cfg_hash['columns']).select { |c| c.is_a?(Hash) }
    overlapping = []
    cols.each_with_index do |c, idx|
      cw    = c['width'].to_f
      dep   = c['depth'].to_f
      side  = c['side'].to_s == 'right' ? 'right' : 'left'
      dist  = c['distance'].to_f
      plane = c['wall_plane'].to_s == 'side_y' ? 'side_y' : 'back_x'

      if plane == 'side_y'
        # خلع على الضلع الجانبي في وحدات الركنة (الزاوية)
        y0 = [dist, 0.0].max
        y1 = [dist + cw, cab_d_cm].min
        next unless (y1 - y0) > 0.3 && dep > 0.3
        overlapping << {
          'index'      => idx + 1,
          'wall_plane' => 'side_y',
          'side'       => side,
          'y0_cm'      => y0,
          'y1_cm'      => y1,
          'width_cm'   => (y1 - y0).round(1),
          'depth_cm'   => [dep, cab_w_cm - 5.0].min.round(1),
          'mode'       => (c['mode'].to_s == 'true_notch' ? 'true_notch' : 'depth_avoid')
        }
      else
        wx0 = (side == 'right') ? (wall_w - dist - cw) : dist
        wx1 = wx0 + cw
        x0  = [wx0 - cab_start, 0.0].max
        x1  = [wx1 - cab_start, cab_w_cm].min
        next unless (x1 - x0) > 0.3 && dep > 0.3
        overlapping << {
          'index'      => idx + 1,
          'wall_plane' => 'back_x',
          'side'       => side,
          'x0_cm'      => x0,
          'x1_cm'      => x1,
          'width_cm'   => (x1 - x0).round(1),
          'depth_cm'   => [dep, cab_d_cm - 5.0].min.round(1),
          'mode'       => (c['mode'].to_s == 'true_notch' ? 'true_notch' : 'depth_avoid')
        }
      end
    end

    unit.set_attribute(RELIEF_DICT, 'config_json', cfg_hash.to_json)

    if overlapping.empty?
      UI.messagebox("⚠️ تم حفظ إعدادات الحائط والعمود، ولكن العمود المدخل لا يتقاطع مع موقع هذه الوحدة حالياً (عرض الوحدة #{cab_w_cm} سم على بُعد #{cab_off} سم).")
      refresh_unit_options_dialog_if_open(unit)
      return true
    end

    model = Sketchup.active_model
    model.start_operation('تطبيق الخلع والعمود على وحدة المطبخ - مكتبة محمد عادل', true)

    begin
      payload = extract_unit_dc_options_payload(unit)
      fields  = Array(payload[:fields])
      depth_field = fields.find do |f|
        f['access'] != 'VIEW' && (f['key'].to_s.downcase == 'leny' || (f['label'].to_s.include?('عمق') && !f['label'].to_s.include?('درج')))
      end

      max_avoid_depth_cm = overlapping.select { |r| r['mode'] == 'depth_avoid' }.map { |r| r['depth_cm'].to_f }.max.to_f
      notch_items        = overlapping.select { |r| r['mode'] == 'true_notch' }
      max_notch_depth_cm = notch_items.map { |r| r['depth_cm'].to_f }.max.to_f

      if max_avoid_depth_cm > 0.3 && depth_field
        cur_depth_cm = depth_field['value'].to_f
        cur_depth_cm = cab_d_cm if cur_depth_cm <= 1.0
        new_depth_cm = [cur_depth_cm - max_avoid_depth_cm, 15.0].max.round(1)

        unit.set_attribute(RELIEF_DICT, 'orig_depth_key', depth_field['key'].to_s)
        unit.set_attribute(RELIEF_DICT, 'orig_depth_val', cur_depth_cm.to_s)

        apply_unit_dc_options_changes!({ depth_field['key'].to_s => new_depth_cm.to_s }, false)

        forward_vec = unit.transformation.yaxis.clone
        if forward_vec.length > 1e-6
          forward_vec.normalize!
          shift_v = Geom::Vector3d.new(
            -forward_vec.x * max_avoid_depth_cm.cm,
            -forward_vec.y * max_avoid_depth_cm.cm,
            -forward_vec.z * max_avoid_depth_cm.cm
          )
          unit.transform!(Geom::Transformation.translation(shift_v))
          unit.set_attribute(RELIEF_DICT, 'shifted_world_vec', [shift_v.x, shift_v.y, shift_v.z])
        end
      end

      if !notch_items.empty? && unit.is_a?(Sketchup::ComponentInstance)
        unit.make_unique if unit.definition.count_used_instances > 1
        defn = unit.definition

        c_info = analyze_kitchen_unit_carcass(unit, payload)
        sx     = c_info[:sx]
        sy     = c_info[:sy]
        cx_min = c_info[:cx_min]
        cx_max = c_info[:cx_max]
        cy_min = c_info[:cy_min]
        by1    = c_info[:cy_max]
        bz0    = c_info[:cz_min]
        bz1    = c_info[:cz_max]

        tx_board = 1.8.cm / sx
        ty_board = 1.8.cm / sy

        # جلب خامة الشاسيه (الكونتر الأبيض) الأصلية مطابقة 100% للوحدة بدون إنشاء أي خامة جديدة
        carcass_mat_spec = find_kitchen_carcass_material_spec(unit)

        x_notches = []
        y_notches = []

        notch_items.each do |notch|
          if notch['wall_plane'] == 'side_y'
            ny0  = cy_min + (notch['y0_cm'].to_f.cm / sy)
            ny1  = [cy_min + (notch['y1_cm'].to_f.cm / sy), by1].min
            ndep = notch['depth_cm'].to_f.cm / sx
            y_notches << { :notch => notch, :ny0 => ny0, :ny1 => ny1, :ndep => ndep }
          else
            nx0  = cx_min + (notch['x0_cm'].to_f.cm / sx)
            nx1  = [cx_min + (notch['x1_cm'].to_f.cm / sx), cx_max].min
            ndep = notch['depth_cm'].to_f.cm / sy
            x_notches << { :notch => notch, :nx0 => nx0, :nx1 => nx1, :ndep => ndep }
          end
        end

        # 1. تخصيم أو تقسيم الضهر الأصلي لجزئين + قراءة سقوط المحفار وتخانة الضهر
        back_info = process_back_panels_and_groove_for_notches!(
          defn, c_info, x_notches, y_notches, carcass_mat_spec, unit.transformation
        )

        # 2. تصغير عمق الأدراج بقيمة بروز الخلع
        if max_notch_depth_cm > 0.3
          adjust_kitchen_drawers_for_relief!(unit, c_info, max_notch_depth_cm, payload)
        end

        # 3. إنشاء تجاليد الخلع + استكمال الضهر بنفس قيمة سقوط المحفار (أو بداية من الخلف)
        x_notches.each do |xn|
          notch = xn[:notch]
          nx0   = xn[:nx0]
          nx1   = xn[:nx1]
          ndep  = xn[:ndep]
          by0   = by1 - ndep

          g_drop_y = back_info[:groove_drop_y].to_f
          t_back_y = back_info[:thick_y].to_f
          b_z0     = back_info[:z0] || bz0
          b_z1     = back_info[:z1] || bz1
          b_mat    = back_info[:mat_spec] || carcass_mat_spec

          # (أ) الجنب الأيسر للخلع
          create_kitchen_relief_board_instance!(
            defn,
            "جنب خلع عمود #{notch['index']} (يسار)",
            nx0, nx0 + tx_board,
            by0, by1,
            bz0, bz1,
            carcass_mat_spec,
            unit.transformation
          )

          # (ب) الجنب الأيمن للخلع
          if (nx1 - nx0) > (tx_board * 2.1)
            create_kitchen_relief_board_instance!(
              defn,
              "جنب خلع عمود #{notch['index']} (يمين)",
              nx1 - tx_board, nx1,
              by0, by1,
              bz0, bz1,
              carcass_mat_spec,
              unit.transformation
            )
          end

          # (ج) استكمال الضهر أمام الخلع بنفس قيمة سقوط المحفار (أو بداية من خلف الخلع إذا كان السقوط 0)
          inner_x0 = (nx1 - nx0) > (tx_board * 2.2) ? (nx0 + tx_board) : nx0
          inner_x1 = (nx1 - nx0) > (tx_board * 2.2) ? (nx1 - tx_board) : nx1
          back_y1  = by0 - g_drop_y
          back_y0  = back_y1 - t_back_y

          create_kitchen_relief_board_instance!(
            defn,
            "استكمال ضهر خلع عمود #{notch['index']}",
            inner_x0, inner_x1,
            back_y0, back_y1,
            b_z0, b_z1,
            b_mat,
            unit.transformation
          )
        end

        # 4. إنشاء تجاليد واستكمال الضهر للخلع الجانبي في وحدات الركنة (side_y)
        y_notches.each do |yn|
          notch = yn[:notch]
          ny0   = yn[:ny0]
          ny1   = yn[:ny1]
          ndep  = yn[:ndep]
          is_right_wing = (notch['side'].to_s == 'right')

          g_drop_x = back_info[:groove_drop_x].to_f
          t_back_x = back_info[:thick_x].to_f
          b_z0     = back_info[:z0] || bz0
          b_z1     = back_info[:z1] || bz1
          b_mat    = back_info[:mat_spec] || carcass_mat_spec

          if is_right_wing
            wx1 = cx_max
            wx0 = wx1 - ndep
            back_x1 = wx0 - g_drop_x
            back_x0 = back_x1 - t_back_x
          else
            wx0 = cx_min
            wx1 = wx0 + ndep
            back_x0 = wx1 + g_drop_x
            back_x1 = back_x0 + t_back_x
          end

          create_kitchen_relief_board_instance!(
            defn,
            "جنب خلع ركنة #{notch['index']} (أمامي)",
            wx0, wx1,
            ny0, ny0 + ty_board,
            bz0, bz1,
            carcass_mat_spec,
            unit.transformation
          )

          if (ny1 - ny0) > (ty_board * 2.1)
            create_kitchen_relief_board_instance!(
              defn,
              "جنب خلع ركنة #{notch['index']} (خلفي)",
              wx0, wx1,
              ny1 - ty_board, ny1,
              bz0, bz1,
              carcass_mat_spec,
              unit.transformation
            )
          end

          inner_y0 = (ny1 - ny0) > (ty_board * 2.2) ? (ny0 + ty_board) : ny0
          inner_y1 = (ny1 - ny0) > (ty_board * 2.2) ? (ny1 - ty_board) : ny1

          create_kitchen_relief_board_instance!(
            defn,
            "استكمال ضهر خلع ركنة #{notch['index']}",
            back_x0, back_x1,
            inner_y0, inner_y1,
            b_z0, b_z1,
            b_mat,
            unit.transformation
          )
        end
      end

      model.commit_operation
      model.active_view.invalidate
      refresh_unit_options_dialog_if_open(unit)
      UI.messagebox("✅ تم تطبيق الخلع والعمود على الوحدة بنجاح!\n\n• تم الحفاظ على نفس خامة الكونتر الأبيض الأصلية في OpenCutList.\n• تم تخصيم/تقسيم لوح الضهر واستكماله بنفس سقوط المحفار.\n• تم تصغير عمق الأدراج بقيمة بروز الخلع تلقائياً.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء تطبيق الخلع والعمود:\n#{e.message}")
      false
    end
  end

  # ============================================================================
  #  نافذة «خيارات الوحدة — مكتبة محمد عادل» (بديلة Component Options)
  # ============================================================================
  @unit_options_dlg = nil
  @unit_options_selection_observer = nil

  class DolaUnitOptionsSelectionObserver < Sketchup::SelectionObserver
    def onSelectionBulkChange(_selection)
      DolaSmartLibraryPlugin.refresh_unit_options_dialog_if_open
    end
    def onSelectionCleared(_selection)
      DolaSmartLibraryPlugin.refresh_unit_options_dialog_if_open
    end
  end

  def self.dc_engine_instance
    return nil unless defined?($dc_observers) && $dc_observers
    $dc_observers.get_latest_class
  rescue
    nil
  end

  def self.unescape_dc_string(raw)
    s = raw.to_s
    s = s.gsub(/%u([0-9A-Fa-f]{4})/) { [$1.hex].pack('U') }
    s = CGI.unescape(s) rescue s
    s.strip
  rescue
    raw.to_s.strip
  end

  def self.clean_dc_label(raw)
    s = unescape_dc_string(raw)
    s = s.gsub(/&lt;/i, '<').gsub(/&gt;/i, '>').gsub(/&quot;/i, '"').gsub(/&#39;/i, "'").gsub(/&amp;/i, '&')
    s = s.gsub(/<style[^>]*>.*?<\/style>/im, '')
    s = s.gsub(/<\/?[a-zA-Z][^>]*>/, ' ')
    s = s.gsub(/\b(?:font-size|font-family|font-weight|color|size|face|style)\s*=\s*["']?[^"'\s>]+["']?/i, ' ')
    s = s.sub(/\A\s*=+\s*/, '')
    s = s.gsub(/\s+/, ' ').strip
    s
  rescue
    raw.to_s.strip
  end

  def self.find_selected_dc_unit(preferred = nil)
    if preferred && preferred.valid? && preferred.is_a?(Sketchup::ComponentInstance)
      return preferred
    end
    sel = Sketchup.active_model.selection.to_a
    inst = sel.find { |e| e.is_a?(Sketchup::ComponentInstance) && dynamic?(e) }
    inst ||= sel.find { |e| e.is_a?(Sketchup::ComponentInstance) }
    inst
  rescue
    nil
  end

  def self.dc_attr_meta(unit, key, attr_suffix)
    meta_key = "_#{key}_#{attr_suffix}"
    val = unit.get_attribute('dynamic_attributes', meta_key, nil)
    if val.nil? && unit.respond_to?(:definition) && unit.definition
      val = unit.definition.get_attribute('dynamic_attributes', meta_key, nil)
    end
    val
  rescue
    nil
  end

  def self.dc_is_length_attribute?(unit, key, units_str, formula_units_str, label_str)
    k = key.to_s.downcase
    return true if %w[lenx leny lenz x y z].include?(k)

    u  = units_str.to_s.upcase.strip
    fu = formula_units_str.to_s.upcase.strip
    return true if %w[CENTIMETERS MILLIMETERS METERS INCHES FEET].include?(u)
    return true if %w[CENTIMETERS MILLIMETERS METERS INCHES FEET].include?(fu)
    return false if %w[STRING INTEGER FLOAT BOOLEAN PERCENT].include?(u)

    if u.empty? || u == 'DEFAULT'
      lbl = label_str.to_s
      dim_words = %w[عرض ارتفاع عمق طول سمك تخانة تخانات مسافة رحرحة سقوط بروز خصم مقاس شاسيه رجل رجول وزرة فراغ قطر]
      return true if dim_words.any? { |w| lbl.include?(w) }
    end
    false
  end

  def self.extract_unit_dc_options_payload(unit)
    return { :has_unit => false } unless unit && unit.valid? && unit.is_a?(Sketchup::ComponentInstance)

    d_type = respond_to?(:dressing_unit_type) ? dressing_unit_type(unit) : nil

    d = dc_engine_instance
    inst_dict = unit.attribute_dictionary('dynamic_attributes', false)
    def_dict  = unit.definition.attribute_dictionary('dynamic_attributes', false)

    all_keys = []
    [def_dict, inst_dict].compact.each do |dict|
      dict.each_pair do |k, _v|
        ks = k.to_s
        if ks.start_with?('_') && ks.end_with?('_access')
          base_k = ks.sub(/\A_/, '').sub(/_access\z/, '')
          all_keys << base_k
        end
      end
    end
    all_keys.uniq!

    fields = []
    all_keys.each do |key|
      access = begin
        (d ? d.get_attribute_access(unit, key) : nil) || dc_attr_meta(unit, key, 'access')
      rescue
        dc_attr_meta(unit, key, 'access')
      end
      access = access.to_s.upcase.strip
      next if access.empty? || access == 'NONE'

      raw_label = begin
        (d ? d.get_attribute_formlabel(unit, key) : nil) ||
          dc_attr_meta(unit, key, 'formlabel') ||
          dc_attr_meta(unit, key, 'label') ||
          key
      rescue
        dc_attr_meta(unit, key, 'formlabel') || key
      end
      label = clean_dc_label(raw_label)
      label = key.to_s if label.empty?

      units_str = begin
        (d ? d.get_attribute_units(unit, key) : nil) || dc_attr_meta(unit, key, 'units')
      rescue
        dc_attr_meta(unit, key, 'units')
      end.to_s.upcase.strip

      formula_units_str = begin
        (d ? d.get_attribute_formulaunits(unit, key) : nil) || dc_attr_meta(unit, key, 'formulaunits')
      rescue
        dc_attr_meta(unit, key, 'formulaunits')
      end.to_s.upcase.strip

      raw_val = begin
        v = d ? d.get_attribute_value(unit, key) : nil
        v = unit.get_attribute('dynamic_attributes', key, nil) if v.nil?
        v = unit.definition.get_attribute('dynamic_attributes', key, nil) if v.nil?
        v
      rescue
        unit.get_attribute('dynamic_attributes', key, nil)
      end

      is_len = dc_is_length_attribute?(unit, key, units_str, formula_units_str, label)

      options_list = []
      if access == 'LIST'
        raw_opts = begin
          (d ? d.get_attribute_options(unit, key) : nil) || dc_attr_meta(unit, key, 'options')
        rescue
          dc_attr_meta(unit, key, 'options')
        end.to_s

        raw_opts.split('&').each do |pair|
          next if pair.strip.empty?
          lbl_enc, val_enc = pair.split('=', 2)
          opt_label = clean_dc_label(lbl_enc || pair)
          opt_val   = unescape_dc_string(val_enc || lbl_enc || pair)
          options_list << { 'label' => opt_label, 'value' => opt_val }
        end
      end

      display_val = ''
      unit_badge  = ''

      if access == 'LIST'
        cur_str = raw_val.to_s.strip
        matched_opt = options_list.find { |o| o['value'].to_s.strip.downcase == cur_str.downcase }
        if !matched_opt && cur_str =~ /\A-?\d+(\.\d+)?\z/
          num = cur_str.to_f
          matched_opt = options_list.find do |o|
            ov = o['value'].to_s.strip
            next false unless ov =~ /\A-?\d+(\.\d+)?\z/
            (ov.to_f - num).abs < 0.005 || ((ov.to_f / 2.54) - num).abs < 0.005 || ((ov.to_f * 2.54) - num).abs < 0.005
          end
        end
        display_val = matched_opt ? matched_opt['value'] : cur_str
      elsif is_len
        if units_str == 'MILLIMETERS'
          display_val = (raw_val.to_f * 25.4).round(2).to_s.sub(/\.0+\z/, '')
          unit_badge  = 'مم'
        elsif units_str == 'METERS'
          display_val = (raw_val.to_f * 0.0254).round(3).to_s.sub(/\.0+\z/, '')
          unit_badge  = 'م'
        else
          display_val = (raw_val.to_f * 2.54).round(2).to_s.sub(/\.0+\z/, '')
          unit_badge  = 'سم'
        end
      else
        display_val = clean_dc_label(raw_val.to_s)
        if display_val =~ /\A-?\d+\.\d+\z/
          display_val = display_val.to_f.round(2).to_s.sub(/\.0+\z/, '')
        end
      end

      norm_lbl = label.gsub(/\s+/, '')
      # استبعاد الحقول الوهمية التي تحمل عنوان "المكون الرئيسي" فقط للعرض
      next if access == 'VIEW' && (norm_lbl.include?('المكونالرئيسي') || norm_lbl.include?('مكونرئيسي'))

      is_primary_dim = (
        access != 'VIEW' &&
        (norm_lbl.include?('عرض') || norm_lbl.include?('ارتفاع') || norm_lbl.include?('عمق')) &&
        !norm_lbl.include?('درج') && !norm_lbl.include?('رف')
      )

      fields << {
        'key'            => key,
        'label'          => label,
        'access'         => access,
        'is_length'      => is_len,
        'units'          => units_str,
        'formula_units'  => formula_units_str,
        'unit_badge'     => unit_badge,
        'value'          => display_val,
        'options'        => options_list,
        'is_primary_dim' => is_primary_dim
      }
    end

    fields.sort_by! { |f| f['key'].to_s.downcase }

    bb = unit.bounds
    w_cm = (bb.width.to_f * 2.54).round(1)
    d_cm = (bb.depth.to_f * 2.54).round(1)
    h_cm = (bb.height.to_f * 2.54).round(1)

    unit_title = resolve_library_unit_display_name(unit)

    grain_show_active = DolaWoodGrainManager.show_all_grain_active?
    wall_relief_cfg   = read_unit_wall_relief_config(unit, w_cm)

    {
      :has_unit              => true,
      :entity_id             => unit.entityID,
      :unit_name             => unit_title,
      :dressing_type         => d_type.to_s,
      :bbox_w_cm             => w_cm,
      :bbox_d_cm             => d_cm,
      :bbox_h_cm             => h_cm,
      :auto_open             => auto_open_options_enabled?,
      :grain_show_all_active => grain_show_active,
      :wall_relief           => wall_relief_cfg,
      :fields                => fields
    }
  rescue => e
    { :has_unit => false, :error => e.message }
  end

  def self.apply_unit_dc_options_changes!(changes_hash, refresh_dialog = true)
    return false unless changes_hash.is_a?(Hash) && !changes_hash.empty?
    unit = find_selected_dc_unit
    unless unit && unit.valid?
      UI.messagebox('الرجاء تحديد الوحدة أولاً في سكتش أب.')
      return false
    end

    d = dc_engine_instance
    unless d
      UI.messagebox('إضافة Dynamic Components غير مفعلة في سكتش أب.')
      return false
    end

    payload = extract_unit_dc_options_payload(unit)
    field_map = {}
    Array(payload[:fields]).each { |f| field_map[f['key'].to_s] = f }

    model = Sketchup.active_model
    model.start_operation('تحديث خيارات الوحدة - مكتبة محمد عادل', true)

    begin
      forced = {}
      changes_hash.each do |raw_key, user_val|
        key = raw_key.to_s
        meta = field_map[key]
        next unless meta
        next if meta['access'] == 'VIEW'

        val_str = user_val.to_s.strip
        next if val_str == meta['value'].to_s.strip

        internal_val = val_str

        if meta['access'] == 'LIST'
          if meta['is_length'] && val_str =~ /\A-?\d+(\.\d+)?\z/ && meta['formula_units'] == 'CENTIMETERS'
            internal_val = (val_str.to_f / 2.54)
          else
            internal_val = val_str
          end
        elsif meta['is_length']
          num = val_str.tr('٠١٢٣٤٥٦٧٨٩', '0123456789').to_f
          if meta['units'] == 'MILLIMETERS'
            internal_val = num / 25.4
          elsif meta['units'] == 'METERS'
            internal_val = num / 0.0254
          else
            internal_val = num / 2.54
          end
        elsif meta['units'] == 'INTEGER'
          internal_val = val_str.tr('٠١٢٣٤٥٦٧٨٩', '0123456789').to_i
        elsif meta['units'] == 'FLOAT'
          internal_val = val_str.tr('٠١٢٣٤٥٦٧٨٩', '0123456789').to_f
        end

        if meta['access'] != 'LIST'
          formula_key = "_#{key}_formula"
          unit.delete_attribute('dynamic_attributes', formula_key) rescue nil
        end

        begin
          d.set_attribute(unit, key, internal_val)
        rescue
          unit.set_attribute('dynamic_attributes', key, internal_val)
        end
        unit.set_attribute('dynamic_attributes', key, internal_val)
        forced[key] = internal_val
      end

      unless forced.empty?
        saved_grain_states = DolaWoodGrainManager.restore_dc_axes_before_redraw!(unit)
        forced.each { |k, v| d.set_forced_config_value(unit, k, v) rescue nil }
        d.run_all_formulas(unit) rescue nil
        d.redraw(unit, false, false) rescue nil
        d.update_last_sizes(unit) rescue nil

        d.clear_forced_config_values(unit) rescue nil
        d.run_all_formulas(unit) rescue nil
        d.redraw(unit, false, false) rescue nil
        d.update_last_sizes(unit) rescue nil

        DolaWoodGrainManager.reapply_grain_after_redraw!(unit)
      end

      model.commit_operation
      model.active_view.invalidate
      refresh_unit_options_dialog_if_open(unit) if refresh_dialog
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء تطبيق خيارات الوحدة:\n#{e.message}")
      false
    end
  end

  def self.refresh_unit_options_dialog_if_open(preferred_unit = nil)
    return false unless @unit_options_dlg && @unit_options_dlg.visible?
    unit = find_selected_dc_unit(preferred_unit)
    data = extract_unit_dc_options_payload(unit)
    @unit_options_dlg.execute_script("window.receiveUnitPayload(#{data.to_json});") rescue nil
    true
  rescue
    false
  end

  def self.open_unit_options_dialog(preferred_unit = nil)
    unit = find_selected_dc_unit(preferred_unit)

    if unit && respond_to?(:dressing_unit_type)
      dtype = dressing_unit_type(unit)
      if dtype && !dtype.to_s.empty?
        return open_dressing_design_tool(dtype, unit)
      end
    end

    unless @unit_options_selection_observer
      @unit_options_selection_observer = DolaUnitOptionsSelectionObserver.new
      Sketchup.active_model.selection.add_observer(@unit_options_selection_observer) rescue nil
    end

    if @unit_options_dlg && @unit_options_dlg.visible?
      refresh_unit_options_dialog_if_open(unit)
      @unit_options_dlg.bring_to_front rescue nil
      return true
    end

    @unit_options_dlg = UI::HtmlDialog.new({
      :dialog_title    => 'خيارات الوحدة والخلع — مكتبة محمد عادل',
      :preferences_key => 'DolaKitchenUnitOptions_v4',
      :scrollable      => false,
      :resizable       => true,
      :width           => 490,
      :height          => 680,
      :left            => 240,
      :top             => 80,
      :style           => UI::HtmlDialog::STYLE_DIALOG
    })

    initial_payload = extract_unit_dc_options_payload(unit).to_json

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@400;500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; }
          html, body {
            margin: 0; padding: 0;
            width: 100%; height: 100%;
            font-family: 'Tajawal', Tahoma, sans-serif;
            background: radial-gradient(circle at top right, #1e1b4b 0%, #0f172a 65%, #090d16 100%);
            color: #f8fafc;
            overflow: hidden;
          }
          .app-wrap {
            display: flex;
            flex-direction: column;
            height: 100vh;
            padding: 8px 9px;
            gap: 6px;
          }
          .hero-card {
            background: linear-gradient(135deg, rgba(30, 27, 75, 0.94) 0%, rgba(15, 23, 42, 0.96) 100%);
            border: 1px solid rgba(56, 189, 248, 0.35);
            border-radius: 11px;
            padding: 6px 10px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 8px;
            box-shadow: 0 6px 18px rgba(0, 0, 0, 0.35);
          }
          .hero-right {
            display: flex;
            align-items: center;
            gap: 8px;
            min-width: 0;
          }
          .hero-badge {
            width: 32px;
            height: 32px;
            border-radius: 8px;
            background: linear-gradient(135deg, #0284c7 0%, #1e1b4b 100%);
            border: 1px solid #38bdf8;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 15px;
            flex-shrink: 0;
          }
          .hero-titles { min-width: 0; }
          .hero-brand {
            font-size: 10px;
            font-weight: 800;
            color: #fbbf24;
            line-height: 1.1;
          }
          .hero-unit-name {
            font-size: 14.5px;
            font-weight: 800;
            color: #ffffff;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
            line-height: 1.25;
          }
          .dims-pill {
            background: rgba(2, 132, 199, 0.16);
            border: 1px solid rgba(56, 189, 248, 0.4);
            color: #38bdf8;
            padding: 3px 8px;
            border-radius: 8px;
            font-size: 11px;
            font-weight: 700;
            white-space: nowrap;
            direction: ltr;
          }

          .tabs-bar {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 5px;
            background: rgba(15, 23, 42, 0.85);
            padding: 3px;
            border-radius: 9px;
            border: 1px solid rgba(255, 255, 255, 0.12);
          }
          .tab-btn {
            background: transparent;
            border: none;
            color: #94a3b8;
            padding: 5px 8px;
            border-radius: 7px;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 800;
            cursor: pointer;
            transition: all 0.15s;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 5px;
          }
          .tab-btn:hover { color: #ffffff; background: rgba(255, 255, 255, 0.06); }
          .tab-btn.active {
            background: linear-gradient(135deg, #0284c7 0%, #1d4ed8 100%);
            color: #ffffff;
          }
          .tab-btn.relief-active {
            background: linear-gradient(135deg, #d97706 0%, #b45309 100%);
            color: #ffffff;
          }

          .toolbar-strip {
            display: flex;
            gap: 5px;
            align-items: center;
          }
          .search-box {
            flex: 1;
            background: rgba(15, 23, 42, 0.85);
            border: 1px solid rgba(255, 255, 255, 0.14);
            border-radius: 8px;
            padding: 5px 9px;
            color: #f8fafc;
            font-family: 'Tajawal', sans-serif;
            font-size: 11.5px;
            outline: none;
            height: 29px;
          }
          .search-box:focus { border-color: #38bdf8; }
          .quick-grain-btn {
            background: linear-gradient(135deg, #d97706 0%, #b45309 100%);
            border: 1px solid rgba(251, 191, 36, 0.5);
            color: #ffffff;
            border-radius: 8px;
            padding: 4px 8px;
            height: 29px;
            font-family: 'Tajawal', sans-serif;
            font-size: 11px;
            font-weight: 800;
            cursor: pointer;
            white-space: nowrap;
            transition: all 0.15s;
          }
          .quick-grain-btn.is-active {
            background: linear-gradient(135deg, #059669 0%, #047857 100%);
            border-color: #34d399;
          }
          .quick-flip-btn {
            background: linear-gradient(135deg, #ea580c 0%, #9a3412 100%);
            border: 1px solid rgba(253, 186, 116, 0.5);
            color: #ffffff;
            border-radius: 8px;
            padding: 4px 8px;
            height: 29px;
            font-family: 'Tajawal', sans-serif;
            font-size: 11px;
            font-weight: 800;
            cursor: pointer;
            white-space: nowrap;
          }

          .fields-scroll {
            flex: 1;
            overflow-y: auto;
            overflow-x: hidden;
            display: flex;
            flex-direction: column;
            gap: 6px;
            padding-left: 3px;
          }
          .fields-scroll::-webkit-scrollbar { width: 5px; }
          .fields-scroll::-webkit-scrollbar-thumb {
            background: rgba(56, 189, 248, 0.35);
            border-radius: 99px;
          }

          .section-card {
            background: rgba(30, 41, 59, 0.65);
            border: 1px solid rgba(255, 255, 255, 0.11);
            border-radius: 10px;
            padding: 7px 9px;
            display: flex;
            flex-direction: column;
            gap: 4px;
          }
          .section-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 11.5px;
            font-weight: 800;
            color: #38bdf8;
            padding-bottom: 3px;
            margin-bottom: 1px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.08);
          }
          .primary-dims-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(110px, 1fr));
            gap: 5px;
          }
          .dim-box {
            background: rgba(15, 23, 42, 0.85);
            border: 1px solid rgba(56, 189, 248, 0.24);
            border-radius: 8px;
            padding: 4px 7px;
            display: flex;
            flex-direction: column;
            gap: 2px;
          }
          .dim-box label {
            font-size: 11px;
            font-weight: 700;
            color: #e2e8f0;
          }
          .input-with-unit {
            position: relative;
            display: flex;
            align-items: center;
          }
          .field-input, .field-select {
            width: 100%;
            background: #0f172a;
            border: 1px solid rgba(148, 163, 184, 0.32);
            border-radius: 7px;
            padding: 3px 8px;
            height: 27px;
            color: #ffffff;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 700;
            outline: none;
          }
          .field-input:focus, .field-select:focus {
            border-color: #38bdf8;
            box-shadow: 0 0 0 2px rgba(56, 189, 248, 0.18);
          }
          .unit-tag {
            position: absolute;
            left: 7px;
            font-size: 10.5px;
            font-weight: 800;
            color: #fbbf24;
            pointer-events: none;
          }
          .has-unit .field-input { padding-left: 30px; }

          .option-row {
            display: grid;
            grid-template-columns: 1.15fr 1fr;
            align-items: center;
            gap: 6px;
            padding: 3px 7px;
            border-radius: 7px;
            background: rgba(15, 23, 42, 0.55);
            border: 1px solid rgba(255, 255, 255, 0.05);
          }
          .option-row:hover {
            border-color: rgba(56, 189, 248, 0.28);
            background: rgba(15, 23, 42, 0.8);
          }
          .option-label {
            font-size: 12px !important;
            font-weight: 700 !important;
            color: #f1f5f9 !important;
            line-height: 1.25;
          }
          .readonly-badge {
            background: rgba(255, 255, 255, 0.06);
            border: 1px dashed rgba(255, 255, 255, 0.18);
            border-radius: 6px;
            padding: 3px 8px;
            font-size: 11.5px;
            font-weight: 700;
            color: #94a3b8;
            text-align: center;
          }

          .grid2 {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 5px;
          }
          .relief-col-card {
            background: rgba(15, 23, 42, 0.82);
            border: 1px solid rgba(251, 191, 36, 0.35);
            border-radius: 9px;
            padding: 6px 8px;
            display: flex;
            flex-direction: column;
            gap: 5px;
          }
          .relief-col-title {
            font-size: 11.5px;
            font-weight: 800;
            color: #fbbf24;
          }
          .relief-svg-box {
            background: #09131c;
            border: 1px solid rgba(56, 189, 248, 0.3);
            border-radius: 9px;
            padding: 5px;
            text-align: center;
          }
          .relief-actions {
            display: flex;
            gap: 6px;
          }
          .btn-apply-relief {
            flex: 1;
            background: linear-gradient(135deg, #d97706 0%, #b45309 100%);
            border: 1px solid #fbbf24;
            color: #fff;
            padding: 7px 10px;
            border-radius: 8px;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 800;
            cursor: pointer;
          }
          .btn-remove-relief {
            background: rgba(239, 68, 68, 0.18);
            border: 1px solid rgba(239, 68, 68, 0.45);
            color: #fca5a5;
            padding: 7px 10px;
            border-radius: 8px;
            font-family: 'Tajawal', sans-serif;
            font-size: 11.5px;
            font-weight: 700;
            cursor: pointer;
          }

          .empty-state {
            flex: 1;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            text-align: center;
            padding: 20px 16px;
            background: rgba(30, 41, 59, 0.45);
            border: 1px dashed rgba(56, 189, 248, 0.35);
            border-radius: 12px;
            color: #cbd5e1;
            gap: 8px;
          }

          .footer-panel {
            background: rgba(15, 23, 42, 0.94);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 10px;
            padding: 6px 9px;
            display: flex;
            flex-direction: column;
            gap: 5px;
          }
          .auto-open-row {
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 11px;
            color: #cbd5e1;
          }
          .footer-actions {
            display: flex;
            gap: 6px;
          }
          .apply-btn {
            flex: 1;
            background: linear-gradient(135deg, #0284c7 0%, #0369a1 100%);
            border: 1px solid rgba(56, 189, 248, 0.6);
            color: #ffffff;
            padding: 7px 12px;
            border-radius: 8px;
            font-family: 'Tajawal', sans-serif;
            font-size: 13px;
            font-weight: 800;
            cursor: pointer;
          }
          .refresh-btn {
            background: rgba(255, 255, 255, 0.08);
            border: 1px solid rgba(255, 255, 255, 0.18);
            color: #f8fafc;
            padding: 7px 11px;
            border-radius: 8px;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 700;
            cursor: pointer;
          }
        </style>
      </head>
      <body oncontextmenu="return false;">
        <div class="app-wrap">
          <div class="hero-card">
            <div class="hero-right">
              <div class="hero-badge">⚙️</div>
              <div class="hero-titles">
                <div class="hero-brand">مكتبة محمد عادل الذكية للمطابخ</div>
                <div class="hero-unit-name" id="unitTitle">خيارات الوحدة</div>
              </div>
            </div>
            <div class="dims-pill" id="unitDimsBadge">-- × -- × -- سم</div>
          </div>

          <div class="tabs-bar">
            <button type="button" id="tabBtnOptions" class="tab-btn active" onclick="switchUnitTab('options')">
              📐 مقاسات وخيارات الوحدة
            </button>
            <button type="button" id="tabBtnRelief" class="tab-btn" onclick="switchUnitTab('relief')">
              🧱 الخلع والعمود (خلعة الحائط)
            </button>
          </div>

          <div class="toolbar-strip" id="optionsSearchStrip">
            <input type="text" id="filterInput" class="search-box" placeholder="🔍 ابحث في خيارات الوحدة..." oninput="renderFields()">
            <button type="button" id="grainShowAllBtn" class="quick-grain-btn" onclick="toggleShowAllGrain()" title="إظهار/إخفاء علامات اتجاه الثمرة لكل القطع شاملة الضهريات فوق الوحدة">
              👁️🪵 بيان اتجاه الثمرة
            </button>
            <button type="button" class="quick-flip-btn" onclick="activateManualGrainFlip()" title="تفعيل أداة قلب ثمرة القطعة يدوياً بالضغط عليها">
              🔄 قلب يدوي
            </button>
          </div>

          <div class="fields-scroll" id="fieldsContainer"></div>
          <div class="fields-scroll" id="reliefContainer" style="display:none;"></div>

          <div class="footer-panel" id="optionsFooterPanel">
            <label class="auto-open-row">
              <span>فتح نافذة خيارات الوحدة تلقائياً فور وضع أي وحدة مطبخ</span>
              <input type="checkbox" id="autoOpenCheck" onchange="toggleAutoOpen(this.checked)">
            </label>
            <div class="footer-actions">
              <button type="button" class="apply-btn" onclick="submitChanges()">✨ تطبيق التعديلات على الوحدة</button>
              <button type="button" class="refresh-btn" onclick="requestRefresh()" title="قراءة الوحدة المحددة حالياً">🔄</button>
            </div>
          </div>
        </div>

        <script>
          let currentPayload = #{initial_payload};
          let editedValues = {};
          let activeTab = 'options';
          let wallReliefState = { enabled: 'no', wall_width: 240, placement: 'right', cabinet_offset: 0, columns: [] };

          function esc(s) {
            return String(s == null ? '' : s)
              .replace(/&/g, '&amp;')
              .replace(/</g, '&lt;')
              .replace(/>/g, '&gt;')
              .replace(/"/g, '&quot;');
          }

          function cleanLabelJS(raw) {
            return String(raw == null ? '' : raw)
              .replace(/<[^>]*>/g, ' ')
              .replace(/\b(?:font-size|font-family|font-weight|color|size|face|style)\s*=\s*["']?[^"'\s>]+["']?/gi, ' ')
              .replace(/\s+/g, ' ')
              .trim();
          }

          function switchUnitTab(tab) {
            activeTab = (tab === 'relief') ? 'relief' : 'options';
            document.getElementById('tabBtnOptions').className = 'tab-btn' + (activeTab === 'options' ? ' active' : '');
            document.getElementById('tabBtnRelief').className  = 'tab-btn' + (activeTab === 'relief' ? ' relief-active' : '');
            document.getElementById('optionsSearchStrip').style.display = (activeTab === 'options') ? 'flex' : 'none';
            document.getElementById('fieldsContainer').style.display    = (activeTab === 'options') ? 'flex' : 'none';
            document.getElementById('optionsFooterPanel').style.display = (activeTab === 'options') ? 'flex' : 'none';
            document.getElementById('reliefContainer').style.display    = (activeTab === 'relief')  ? 'flex' : 'none';
            if (activeTab === 'relief') {
              renderReliefTab();
            } else {
              renderFields();
            }
          }

          window.receiveUnitPayload = function(payload) {
            currentPayload = payload || { has_unit: false };
            editedValues = {};
            const autoChk = document.getElementById('autoOpenCheck');
            if (autoChk && currentPayload.auto_open !== undefined) {
              autoChk.checked = !!currentPayload.auto_open;
            }
            const gBtn = document.getElementById('grainShowAllBtn');
            if (gBtn) {
              if (currentPayload.grain_show_all_active) {
                gBtn.classList.add('is-active');
                gBtn.textContent = '🙈 إخفاء بيان الثمرة';
              } else {
                gBtn.classList.remove('is-active');
                gBtn.textContent = '👁️🪵 بيان اتجاه الثمرة';
              }
            }
            const cabW = Number(currentPayload.bbox_w_cm || 60);
            const wr = currentPayload.wall_relief || {};
            wallReliefState = {
              enabled: wr.enabled || 'no',
              wall_width: Math.max(cabW, Number(wr.wall_width || Math.max(cabW, 240))),
              placement: wr.placement === 'left' ? 'left' : 'right',
              cabinet_offset: Math.max(0, Number(wr.cabinet_offset || 0)),
              columns: Array.isArray(wr.columns) && wr.columns.length > 0
                ? wr.columns
                : [{ wall_plane: 'back_x', side: 'right', distance: 0, width: 25, depth: 15, mode: 'true_notch' }]
            };
            if (activeTab === 'relief') {
              renderReliefTab();
            } else {
              renderFields();
            }
          };

          function onFieldInput(key, val) {
            editedValues[key] = val;
          }

          function renderFields() {
            const container = document.getElementById('fieldsContainer');
            const titleEl   = document.getElementById('unitTitle');
            const badgeEl   = document.getElementById('unitDimsBadge');
            const q         = (document.getElementById('filterInput').value || '').trim().toLowerCase();

            if (!currentPayload || !currentPayload.has_unit) {
              titleEl.textContent = 'لم يتم تحديد وحدة';
              badgeEl.textContent = '-- × -- × -- سم';
              container.innerHTML = `
                <div class="empty-state">
                  <div style="font-size:32px;">📦</div>
                  <div style="font-size:14px;font-weight:800;color:#fff;">حدد أي وحدة مطبخ في سكتش أب</div>
                  <div style="font-size:12px;line-height:1.5;">بمجرد تحديد أي وحدة ديناميكية في المشهد ستظهر لك هنا جميع مقاساتها وخياراتها وإعدادات الخلع والعمود.</div>
                </div>
              `;
              return;
            }

            titleEl.textContent = cleanLabelJS(currentPayload.unit_name || 'وحدة مطبخ');
            badgeEl.textContent = `${currentPayload.bbox_w_cm} × ${currentPayload.bbox_d_cm} × ${currentPayload.bbox_h_cm} سم`;

            const allFields = Array.isArray(currentPayload.fields) ? currentPayload.fields : [];
            const filtered = allFields.filter(f => {
              if (!q) return true;
              return cleanLabelJS(f.label).toLowerCase().includes(q) || String(f.key || '').toLowerCase().includes(q);
            });

            if (filtered.length === 0) {
              container.innerHTML = `
                <div class="empty-state">
                  <div style="font-size:13px;font-weight:700;">لا توجد خيارات مطابقة للبحث في هذه الوحدة.</div>
                </div>
              `;
              return;
            }

            const primaryDims = filtered.filter(f => f.is_primary_dim);
            const otherFields = filtered.filter(f => !f.is_primary_dim);

            let html = '';

            if (primaryDims.length > 0) {
              html += `
                <div class="section-card">
                  <div class="section-header">
                    <span>📐 المقاسات الأساسية للوحدة</span>
                    <span style="font-size:10.5px;color:#fbbf24;">بالسنتيمتر</span>
                  </div>
                  <div class="primary-dims-grid">
                    ${primaryDims.map(f => renderPrimaryDimBox(f)).join('')}
                  </div>
                </div>
              `;
            }

            if (otherFields.length > 0) {
              html += `
                <div class="section-card">
                  <div class="section-header">
                    <span>🛠️ خصائص وخيارات الوحدة (${otherFields.length})</span>
                    <span style="font-size:10.5px;color:#94a3b8;">مسميات نظيفة وموحدة</span>
                  </div>
                  ${otherFields.map(f => renderOptionRow(f)).join('')}
                </div>
              `;
            }

            container.innerHTML = html;
          }

          function currentValFor(f) {
            return Object.prototype.hasOwnProperty.call(editedValues, f.key) ? editedValues[f.key] : f.value;
          }

          function renderControlHtml(f) {
            const val = currentValFor(f);
            if (f.access === 'VIEW') {
              return `<div class="readonly-badge">${esc(cleanLabelJS(val))} ${esc(f.unit_badge || '')}</div>`;
            }
            if (f.access === 'LIST' && Array.isArray(f.options) && f.options.length > 0) {
              return `
                <select class="field-select" data-key="${esc(f.key)}" onchange="onFieldInput('${esc(f.key)}', this.value)">
                  ${f.options.map(o => {
                    const sel = String(o.value).trim() === String(val).trim() ? 'selected' : '';
                    return `<option value="${esc(o.value)}" ${sel}>${esc(cleanLabelJS(o.label))}</option>`;
                  }).join('')}
                </select>
              `;
            }
            const hasUnit = f.unit_badge && f.unit_badge.length > 0;
            return `
              <div class="input-with-unit ${hasUnit ? 'has-unit' : ''}">
                <input type="text" class="field-input" data-key="${esc(f.key)}" value="${esc(val)}"
                       oninput="onFieldInput('${esc(f.key)}', this.value)"
                       onkeydown="if(event.key==='Enter'){submitChanges();}">
                ${hasUnit ? `<span class="unit-tag">${esc(f.unit_badge)}</span>` : ''}
              </div>
            `;
          }

          function renderPrimaryDimBox(f) {
            return `
              <div class="dim-box">
                <label>${esc(cleanLabelJS(f.label))}</label>
                ${renderControlHtml(f)}
              </div>
            `;
          }

          function renderOptionRow(f) {
            return `
              <div class="option-row">
                <div class="option-label">${esc(cleanLabelJS(f.label))}</div>
                <div>${renderControlHtml(f)}</div>
              </div>
            `;
          }

          function renderReliefTab() {
            const box = document.getElementById('reliefContainer');
            if (!currentPayload || !currentPayload.has_unit) {
              box.innerHTML = `<div class="empty-state">حدد وحدة مطبخ في سكتش أب لإعداد الخلع والعمود لها.</div>`;
              return;
            }
            const cabW = Number(currentPayload.bbox_w_cm || 60);
            const cols = wallReliefState.columns || [];

            box.innerHTML = `
              <div class="section-card">
                <div class="section-header">
                  <span>🧱 إعدادات الحائط وموقع الوحدة</span>
                  <span style="font-size:10.5px;color:#fbbf24;">يدعم الوحدات المستقيمة والركنة</span>
                </div>
                <div class="grid2">
                  <div class="dim-box">
                    <label>عرض الحائط الكلي (سم)</label>
                    <input type="number" id="wrWallWidth" class="field-input" min="${cabW}" step="1" value="${wallReliefState.wall_width}" oninput="syncReliefFromDOM()">
                  </div>
                  <div class="dim-box">
                    <label>جهة قياس موقع الوحدة</label>
                    <select id="wrPlacement" class="field-select" onchange="syncReliefFromDOM()">
                      <option value="right" ${wallReliefState.placement === 'right' ? 'selected' : ''}>من جهة اليمين</option>
                      <option value="left" ${wallReliefState.placement === 'left' ? 'selected' : ''}>من جهة الشمال</option>
                    </select>
                  </div>
                  <div class="dim-box">
                    <label>المسافة قبل الوحدة (سم)</label>
                    <input type="number" id="wrCabOffset" class="field-input" min="0" step="0.5" value="${wallReliefState.cabinet_offset}" oninput="syncReliefFromDOM()">
                  </div>
                  <div class="dim-box">
                    <label>عدد أعمدة الحائط</label>
                    <input type="number" id="wrColCount" class="field-input" min="1" max="6" step="1" value="${cols.length || 1}" oninput="changeReliefColCount(this.value)">
                  </div>
                </div>
              </div>

              <div id="wrColumnsList" style="display:flex;flex-direction:column;gap:5px;"></div>

              <div class="section-card">
                <div class="section-header">
                  <span>📐 معاينة تخطيطية للعمود والوحدة (مسقط أفقي)</span>
                  <span id="wrOverlapBadge" style="font-size:10.5px;color:#4ade80;"></span>
                </div>
                <div class="relief-svg-box">
                  <svg id="wrPreviewSvg" viewBox="0 0 440 130" width="100%" height="125"></svg>
                </div>
                <div class="relief-actions">
                  <button type="button" class="btn-apply-relief" onclick="submitWallRelief()">✨ تطبيق الخلع والعمود على الوحدة</button>
                  <button type="button" class="btn-remove-relief" onclick="removeWallRelief()">🗑️ إلغاء الخلع</button>
                </div>
              </div>
            `;

            renderReliefColumnCards();
            updateReliefSvgPreview();
          }

          function renderReliefColumnCards() {
            const listEl = document.getElementById('wrColumnsList');
            if (!listEl) return;
            const cols = wallReliefState.columns || [];
            listEl.innerHTML = cols.map((c, i) => `
              <div class="relief-col-card">
                <div class="relief-col-title">📌 عمود الحائط رقم (${i + 1})</div>
                <div class="grid2">
                  <div class="dim-box">
                    <label>ضلع الحائط / الركنة</label>
                    <select class="field-select wr-col-plane" onchange="syncReliefFromDOM()">
                      <option value="back_x" ${(c.wall_plane || 'back_x') === 'back_x' ? 'selected' : ''}>الضهر الخلفي الأساسي</option>
                      <option value="side_y" ${c.wall_plane === 'side_y' ? 'selected' : ''}>الضلع الجانبي (لوحدات الركنة)</option>
                    </select>
                  </div>
                  <div class="dim-box">
                    <label>جهة قياس العمود</label>
                    <select class="field-select wr-col-side" onchange="syncReliefFromDOM()">
                      <option value="right" ${(c.side || 'right') === 'right' ? 'selected' : ''}>من جهة اليمين</option>
                      <option value="left" ${c.side === 'left' ? 'selected' : ''}>من جهة الشمال</option>
                    </select>
                  </div>
                  <div class="dim-box">
                    <label>المسافة من الجهة (سم)</label>
                    <input type="number" class="field-input wr-col-dist" min="0" step="0.5" value="${Number(c.distance || 0)}" oninput="syncReliefFromDOM()">
                  </div>
                  <div class="dim-box">
                    <label>عرض العمود (سم)</label>
                    <input type="number" class="field-input wr-col-width" min="1" step="0.5" value="${Number(c.width || 25)}" oninput="syncReliefFromDOM()">
                  </div>
                  <div class="dim-box">
                    <label>بروز العمود (سم)</label>
                    <input type="number" class="field-input wr-col-depth" min="1" step="0.5" value="${Number(c.depth || 15)}" oninput="syncReliefFromDOM()">
                  </div>
                  <div class="dim-box">
                    <label>طريقة معالجة الخلعة</label>
                    <select class="field-select wr-col-mode" onchange="syncReliefFromDOM()">
                      <option value="true_notch" ${(c.mode || 'true_notch') === 'true_notch' ? 'selected' : ''}>خلع حقيقي + استكمال الضهر وتصغير الأدراج</option>
                      <option value="depth_avoid" ${c.mode === 'depth_avoid' ? 'selected' : ''}>تفاديها بدخول العمق الكلي للوحدة</option>
                    </select>
                  </div>
                </div>
              </div>
            `).join('');
          }

          function changeReliefColCount(val) {
            const count = Math.max(1, Math.min(6, parseInt(val || '1', 10) || 1));
            const cur = wallReliefState.columns || [];
            const next = [];
            for (let i = 0; i < count; i++) {
              next.push(cur[i] || { wall_plane: 'back_x', side: 'right', distance: i * 40, width: 25, depth: 15, mode: 'true_notch' });
            }
            wallReliefState.columns = next;
            renderReliefColumnCards();
            updateReliefSvgPreview();
          }

          function syncReliefFromDOM() {
            const cabW = Number((currentPayload && currentPayload.bbox_w_cm) || 60);
            const wEl = document.getElementById('wrWallWidth');
            const pEl = document.getElementById('wrPlacement');
            const oEl = document.getElementById('wrCabOffset');
            if (wEl) wallReliefState.wall_width = Math.max(cabW, parseFloat(wEl.value || cabW) || cabW);
            if (pEl) wallReliefState.placement  = (pEl.value === 'left') ? 'left' : 'right';
            if (oEl) wallReliefState.cabinet_offset = Math.max(0, parseFloat(oEl.value || '0') || 0);

            const cards = document.querySelectorAll('#wrColumnsList .relief-col-card');
            if (cards.length > 0) {
              wallReliefState.columns = Array.from(cards).map(card => ({
                wall_plane: card.querySelector('.wr-col-plane').value === 'side_y' ? 'side_y' : 'back_x',
                side: card.querySelector('.wr-col-side').value === 'left' ? 'left' : 'right',
                distance: Math.max(0, parseFloat(card.querySelector('.wr-col-dist').value || '0') || 0),
                width: Math.max(1, parseFloat(card.querySelector('.wr-col-width').value || '20') || 20),
                depth: Math.max(1, parseFloat(card.querySelector('.wr-col-depth').value || '15') || 15),
                mode: card.querySelector('.wr-col-mode').value === 'depth_avoid' ? 'depth_avoid' : 'true_notch'
              }));
            }
            updateReliefSvgPreview();
          }

          function updateReliefSvgPreview() {
            const svg = document.getElementById('wrPreviewSvg');
            const badge = document.getElementById('wrOverlapBadge');
            if (!svg || !currentPayload || !currentPayload.has_unit) return;

            const cabW = Math.max(10, Number(currentPayload.bbox_w_cm || 60));
            const W    = Math.max(cabW, Number(wallReliefState.wall_width || cabW));
            const sx   = 380 / W;
            const x0   = 30;
            const baseY = 22;

            const cabStart = (wallReliefState.placement === 'right')
              ? Math.max(0, W - wallReliefState.cabinet_offset - cabW)
              : Math.min(wallReliefState.cabinet_offset, Math.max(0, W - cabW));

            let out = `<line x1="${x0}" y1="${baseY}" x2="${x0 + 380}" y2="${baseY}" stroke="#38bdf8" stroke-width="3"/>`;
            let hitCount = 0;

            const cabX = x0 + cabStart * sx;
            const cabPxW = Math.max(12, cabW * sx);

            (wallReliefState.columns || []).forEach((c, i) => {
              if (c.wall_plane === 'side_y') {
                hitCount++;
                const sideX = (c.side === 'right') ? (cabX + cabPxW - 14) : cabX;
                out += `<rect x="${sideX}" y="${baseY + 8}" width="14" height="44" fill="rgba(245,158,11,0.45)" stroke="#fbbf24" stroke-width="2"/>`;
                out += `<text x="${sideX + 7}" y="${baseY + 64}" fill="#fde68a" font-size="9.5" text-anchor="middle">ركنة ${i + 1}</text>`;
              } else {
                const colLeft = (c.side === 'right') ? (W - c.distance - c.width) : c.distance;
                const cx = x0 + Math.max(0, colLeft) * sx;
                const cw = Math.max(4, c.width * sx);
                const dep = Math.min(50, Math.max(12, c.depth * 1.5));
                const ov0 = Math.max(colLeft, cabStart);
                const ov1 = Math.min(colLeft + c.width, cabStart + cabW);
                if (ov1 - ov0 > 0.3) hitCount++;

                out += `<rect x="${cx}" y="${baseY}" width="${cw}" height="${dep}" fill="rgba(245,158,11,0.38)" stroke="#fbbf24" stroke-width="2"/>`;
                out += `<text x="${cx + cw / 2}" y="${baseY + dep + 12}" fill="#fde68a" font-size="9.5" text-anchor="middle">عمود ${i + 1} (${c.width}×${c.depth})</text>`;
              }
            });

            out += `<rect x="${cabX}" y="${baseY}" width="${cabPxW}" height="70" fill="rgba(34,197,94,0.12)" stroke="#4ade80" stroke-width="2.2" stroke-dasharray="6 4"/>`;
            out += `<text x="${cabX + cabPxW / 2}" y="${baseY + 88}" fill="#4ade80" font-size="10.5" font-weight="bold" text-anchor="middle">الوحدة (${cabW} سم)</text>`;

            svg.innerHTML = out;
            if (badge) {
              badge.textContent = hitCount > 0 ? `يتقاطع مع ${hitCount} عمود` : 'لا يوجد تقاطع حالياً';
              badge.style.color = hitCount > 0 ? '#4ade80' : '#fbbf24';
            }
          }

          function submitWallRelief() {
            syncReliefFromDOM();
            wallReliefState.enabled = 'yes';
            if (window.sketchup && window.sketchup.apply_wall_relief) {
              window.sketchup.apply_wall_relief(JSON.stringify(wallReliefState));
            }
          }

          function removeWallRelief() {
            if (window.sketchup && window.sketchup.remove_wall_relief) {
              window.sketchup.remove_wall_relief();
            }
          }

          function submitChanges() {
            if (!currentPayload || !currentPayload.has_unit) return;
            const keys = Object.keys(editedValues);
            if (keys.length === 0) {
              return;
            }
            if (window.sketchup && window.sketchup.apply_unit_options) {
              window.sketchup.apply_unit_options(JSON.stringify(editedValues));
            }
          }

          function requestRefresh() {
            if (window.sketchup && window.sketchup.refresh_unit_options) {
              window.sketchup.refresh_unit_options();
            }
          }

          function toggleShowAllGrain() {
            if (window.sketchup && window.sketchup.toggle_show_all_grain) {
              window.sketchup.toggle_show_all_grain();
            }
          }

          function activateManualGrainFlip() {
            if (window.sketchup && window.sketchup.activate_manual_grain_flip) {
              window.sketchup.activate_manual_grain_flip();
            }
          }

          function toggleAutoOpen(checked) {
            if (window.sketchup && window.sketchup.set_auto_open) {
              window.sketchup.set_auto_open(checked ? '1' : '0');
            }
          }

          window.receiveUnitPayload(currentPayload);
        </script>
      </body>
      </html>
    HTML

    @unit_options_dlg.set_html(html)

    @unit_options_dlg.add_action_callback('apply_unit_options') do |_ctx, json_str|
      changes = JSON.parse(json_str.to_s) rescue {}
      apply_unit_dc_options_changes!(changes, true)
    end

    @unit_options_dlg.add_action_callback('refresh_unit_options') do |_ctx|
      refresh_unit_options_dialog_if_open
    end

    @unit_options_dlg.add_action_callback('toggle_show_all_grain') do |_ctx|
      DolaWoodGrainManager.toggle_show_all_grain_indicators!
    end

    @unit_options_dlg.add_action_callback('activate_manual_grain_flip') do |_ctx|
      DolaWoodGrainManager.activate_single_part_grain_tool
    end

    @unit_options_dlg.add_action_callback('set_auto_open') do |_ctx, val|
      set_auto_open_options_enabled(val.to_s == '1')
    end

    @unit_options_dlg.add_action_callback('apply_wall_relief') do |_ctx, json_str|
      cfg = JSON.parse(json_str.to_s) rescue {}
      apply_kitchen_unit_wall_relief!(cfg)
    end

    @unit_options_dlg.add_action_callback('remove_wall_relief') do |_ctx|
      unit = find_selected_dc_unit
      remove_kitchen_unit_wall_relief!(unit) if unit
    end

    @unit_options_dlg.show
    true
  rescue => e
    UI.messagebox("تعذر فتح نافذة خيارات الوحدة:\n#{e.message}")
    false
  end

  def self.open_options_protected
    open_unit_options_dialog
  end

  def self.open_options_automatically(instance)
    return false unless auto_open_options_enabled?
    return false unless instance && instance.valid?
    open_unit_options_dialog(instance)
  rescue
    false
  end

  # ============================================================================
  #  مراقب وضع الوحدات في المشهد (PlaceAndUnwrapObserver)
  # ============================================================================
  class PlaceAndUnwrapObserver < Sketchup::EntitiesObserver
    def initialize(target_def, comp_data = nil)
      @target_def = target_def
      @comp_data  = comp_data
      @done       = false
    end

    def onElementAdded(entities, entity)
      return if @done
      return unless entity.is_a?(Sketchup::ComponentInstance)
      return unless entity.definition == @target_def

      @done = true
      model = Sketchup.active_model

      UI.start_timer(0.05, false) do
        begin
          if DolaSmartLibraryPlugin.respond_to?(:write_source_metadata) && @comp_data
            DolaSmartLibraryPlugin.write_source_metadata(entity, @comp_data) rescue nil
          end
          inst2 = DolaSmartLibraryPlugin.unwrap_to_dynamic!(entity)
          if inst2 && inst2.valid?
            if DolaSmartLibraryPlugin.respond_to?(:write_source_metadata) && @comp_data
              DolaSmartLibraryPlugin.write_source_metadata(inst2, @comp_data) rescue nil
            end
            model.selection.clear
            model.selection.add(inst2)
            UI.start_timer(0.15, false) do
              DolaSmartLibraryPlugin.open_options_automatically(inst2) if inst2 && inst2.valid?
            end
          end
        rescue
        ensure
          begin
            entities.remove_observer(self)
          rescue
          end
        end
      end
    end
  end

  def self.install_place_observer_for(definition, comp_data = nil)
    ents = Sketchup.active_model.active_entities
    obs = PlaceAndUnwrapObserver.new(definition, comp_data)
    ents.add_observer(obs)
    UI.start_timer(25.0, false) do
      begin
        ents.remove_observer(obs)
      rescue
      end
    end
  rescue
    false
  end

  # ============================================================================
  #  الأدوات المساعدة الـ 11 كاملة بهوية «مكتبة محمد عادل»
  # ============================================================================

  # 1) جعل كل الكمبوننتات فريدة (Make Unique)
  module MHDESIGN_UNIQUIFY
    def self.make_all_components_unique(entities)
      entities.grep(Sketchup::ComponentInstance).each do |instance|
        next unless instance.valid?
        instance.make_unique if instance.definition.count_used_instances > 1
        make_all_components_unique(instance.definition.entities)
      end
    end

    def self.run_uniquify
      model = Sketchup.active_model
      targets = model.selection.grep(Sketchup::ComponentInstance)
      targets = model.active_entities.grep(Sketchup::ComponentInstance) if targets.empty?

      if targets.empty?
        UI.messagebox('لا توجد كمبوننتات في المشهد حالياً.')
        return false
      end

      model.start_operation('جعل كل الكمبوننتات فريدة - مكتبة محمد عادل', true)
      begin
        targets.each do |inst|
          next unless inst.valid?
          inst.make_unique if inst.definition.count_used_instances > 1
          make_all_components_unique(inst.definition.entities)
        end
        model.commit_operation
        UI.messagebox("✅ تم جعل (#{targets.length}) وحدة وجميع قطعها الفرعية فريدة ومستقلة بنجاح.")
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("حدث خطأ: #{e.message}")
      end
    end
  end

  # 2) أداة التدوير 45 درجة (Rotate 45 Tool) مع مؤشر بصري
  class MHDRotate90Tool
    def activate
      @hovered = nil
      Sketchup.status_text = '↻ أداة التدوير 45°: اضغط كليك شمال على أي وحدة لتدويرها 45 درجة حول مركزها.'
    end

    def deactivate(view)
      @hovered = nil
      view.invalidate if view
    end

    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      ent = ph.best_picked
      @hovered = (ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)) ? ent : nil
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      model = Sketchup.active_model
      ph = view.pick_helper
      ph.do_pick(x, y)
      ent = ph.best_picked
      return unless ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)

      model.start_operation('تدوير الوحدة 45° - مكتبة محمد عادل', true)
      begin
        center = ent.bounds.center
        axis   = Geom::Vector3d.new(0, 0, 1)
        tr     = Geom::Transformation.rotation(center, axis, 45.degrees)
        ent.transform!(tr)
      ensure
        model.commit_operation
      end
      view.invalidate
    end

    def draw(view)
      return unless @hovered && @hovered.valid?
      bb = @hovered.bounds
      pts = (0..7).map { |i| bb.corner(i) }
      edges = [0,1, 1,3, 3,2, 2,0, 4,5, 5,7, 7,6, 6,4, 0,4, 1,5, 2,6, 3,7]
      view.line_width = 3
      view.drawing_color = Sketchup::Color.new(56, 189, 248)
      view.draw(GL_LINES, edges.map { |i| pts[i] })
    rescue
    end
  end

  def self.activate_rotate_tool
    Sketchup.active_model.select_tool(MHDRotate90Tool.new)
  end

  # 3) أداة القلب يمين / شمال (Flip L/R Tool) مع مؤشر بصري
  class MHDFlipLRTool
    def activate
      @hovered = nil
      Sketchup.status_text = '⇆ أداة القلب يمين/شمال: اضغط كليك شمال على أي وحدة لقلبها يميناً ويساراً.'
    end

    def deactivate(view)
      @hovered = nil
      view.invalidate if view
    end

    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      ent = ph.best_picked
      @hovered = (ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)) ? ent : nil
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      model = Sketchup.active_model
      ph = view.pick_helper
      ph.do_pick(x, y)
      ent = ph.best_picked
      return unless ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)

      model.start_operation('قلب الوحدة يمين/شمال - مكتبة محمد عادل', true)
      begin
        tr = ent.transformation
        center = ent.bounds.center
        basis = Geom::Transformation.axes(center, tr.xaxis, tr.yaxis, tr.zaxis)
        mirror_local = Geom::Transformation.scaling(-1, 1, 1)
        ent.transform!(basis * mirror_local * basis.inverse)
      ensure
        model.commit_operation
      end
      view.invalidate
    end

    def draw(view)
      return unless @hovered && @hovered.valid?
      bb = @hovered.bounds
      pts = (0..7).map { |i| bb.corner(i) }
      edges = [0,1, 1,3, 3,2, 2,0, 4,5, 5,7, 7,6, 6,4, 0,4, 1,5, 2,6, 3,7]
      view.line_width = 3
      view.drawing_color = Sketchup::Color.new(251, 191, 36)
      view.draw(GL_LINES, edges.map { |i| pts[i] })
    rescue
    end
  end

  def self.activate_flip_lr_tool
    Sketchup.active_model.select_tool(MHDFlipLRTool.new)
  end

  # 4) أداة اللزق جنب بجنب (Click Side Snap Tool)
  class DolaClickSideSnapTool
    def initialize
      @moving_unit = nil
      @target_unit = nil
      @snap_side   = :right
    end

    def activate
      sel = Sketchup.active_model.selection.find { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
      @moving_unit = sel
      if @moving_unit
        Sketchup.status_text = '🧲 أداة اللزق الجنب بالجنب: تم اختيار الوحدة المتحركة — اضغط الآن على الجانب الأيمن أو الأيسر للوحدة الثابتة المراد اللزق بجانبها.'
      else
        Sketchup.status_text = '🧲 أداة اللزق الجنب بالجنب: الخطوة 1 — اضغط كليك شمال على الوحدة التي تريد تحريكها.'
      end
    end

    def deactivate(view)
      @moving_unit = nil
      @target_unit = nil
      view.invalidate if view
    end

    def onCancel(_reason, view)
      @moving_unit = nil
      @target_unit = nil
      Sketchup.active_model.select_tool(nil)
      view.invalidate if view
    end

    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      picked = ph.best_picked
      if picked && (picked.is_a?(Sketchup::ComponentInstance) || picked.is_a?(Sketchup::Group)) && picked != @moving_unit
        @target_unit = picked
        ip = Sketchup::InputPoint.new
        ip.pick(view, x, y)
        if ip.valid?
          pt = ip.position
          center = picked.bounds.center
          xaxis = picked.transformation.xaxis
          vec = pt - center
          @snap_side = (vec.dot(xaxis) >= 0) ? :right : :left
        end
      else
        @target_unit = nil
      end
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      picked = ph.best_picked
      return unless picked.is_a?(Sketchup::ComponentInstance) || picked.is_a?(Sketchup::Group)

      if @moving_unit.nil? || !@moving_unit.valid?
        @moving_unit = picked
        Sketchup.active_model.selection.clear
        Sketchup.active_model.selection.add(@moving_unit)
        Sketchup.status_text = '🧲 الخطوة 2 — اضغط الآن على الجانب الأيمن أو الأيسر للوحدة الثابتة المراد اللزق بجانبها.'
        view.invalidate
        return
      end

      return if picked == @moving_unit
      snap_unit_next_to!(@moving_unit, picked, @snap_side)
      @moving_unit = nil
      @target_unit = nil
      Sketchup.status_text = '✅ تم لزق ومحاذاة الوحدة بنجاح! اضغط على وحدة جديدة لتحريكها أو Esc للخروج.'
      view.invalidate
    end

    def snap_unit_next_to!(moving, target, side)
      model = Sketchup.active_model
      model.start_operation('لزق وحدة جنب بجنب - مكتبة محمد عادل', true)
      begin
        t_tr = target.transformation
        ux = t_tr.xaxis.clone; ux.normalize!
        uy = t_tr.yaxis.clone; uy.normalize!
        uz = t_tr.zaxis.clone; uz.normalize!

        # تدوير الوحدة المتحركة لتأخذ نفس اتجاه زاوية الوحدة الهدف أولاً
        m_center = moving.bounds.center
        m_tr = moving.transformation
        mx = m_tr.xaxis.clone; mx.normalize!
        my = m_tr.yaxis.clone; my.normalize!
        mz = m_tr.zaxis.clone; mz.normalize!

        from_axes = Geom::Transformation.axes(m_center, mx, my, mz)
        to_axes   = Geom::Transformation.axes(m_center, ux, uy, uz)
        moving.transform!(to_axes * from_axes.inverse)

        # حساب الحدود على محاور الوحدة الهدف
        project_bounds = lambda do |ent|
          bb = ent.bounds
          pts = (0..7).map { |i| bb.corner(i) }
          xs = pts.map { |p| (p - t_tr.origin).dot(ux) }
          ys = pts.map { |p| (p - t_tr.origin).dot(uy) }
          zs = pts.map { |p| (p - t_tr.origin).dot(uz) }
          {
            :min_x => xs.min, :max_x => xs.max,
            :min_y => ys.min, :max_y => ys.max,
            :min_z => zs.min, :max_z => zs.max
          }
        end

        tb = project_bounds.call(target)
        mb = project_bounds.call(moving)

        dx = (side == :right) ? (tb[:max_x] - mb[:min_x]) : (tb[:min_x] - mb[:max_x])
        # محاذاة الظهر والارتفاع السفلي مع الوحدة الهدف
        dy = tb[:min_y] - mb[:min_y]
        dz = tb[:min_z] - mb[:min_z]

        move_vec = Geom::Vector3d.new(
          ux.x * dx + uy.x * dy + uz.x * dz,
          ux.y * dx + uy.y * dy + uz.y * dz,
          ux.z * dx + uy.z * dy + uz.z * dz
        )
        moving.transform!(Geom::Transformation.translation(move_vec))
      ensure
        model.commit_operation
      end
    end

    def draw(view)
      if @moving_unit && @moving_unit.valid?
        bb = @moving_unit.bounds
        pts = (0..7).map { |i| bb.corner(i) }
        edges = [0,1, 1,3, 3,2, 2,0, 4,5, 5,7, 7,6, 6,4, 0,4, 1,5, 2,6, 3,7]
        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(56, 189, 248)
        view.draw(GL_LINES, edges.map { |i| pts[i] })
      end
      if @target_unit && @target_unit.valid?
        bb = @target_unit.bounds
        pts = (0..7).map { |i| bb.corner(i) }
        edges = [0,1, 1,3, 3,2, 2,0, 4,5, 5,7, 7,6, 6,4, 0,4, 1,5, 2,6, 3,7]
        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(16, 185, 129)
        view.draw(GL_LINES, edges.map { |i| pts[i] })
      end
    rescue
    end
  end

  def self.activate_click_side_snap_tool
    Sketchup.active_model.select_tool(DolaClickSideSnapTool.new)
  end

  # 5) أداة ترجمة وتعريب أسماء القطع الداخلية للـ Cutting List
  ARABIC_PART_DICTIONARY = {
    'right_side'   => 'جنب يمين',
    'left_side'    => 'جنب شمال',
    'side_r'       => 'جنب يمين',
    'side_l'       => 'جنب شمال',
    'side'         => 'جنب',
    'top'          => 'سقف / برنيطة',
    'bottom'       => 'قاعدة',
    'base'         => 'قاعدة',
    'shelf'        => 'رف',
    'shelves'      => 'رف',
    'door_r'       => 'ضلفة يمين',
    'door_l'       => 'ضلفة شمال',
    'door'         => 'ضلفة',
    'back'         => 'ضهر',
    'back_panel'   => 'ضهر',
    'drawer_front' => 'وش درج',
    'drawer_side'  => 'جنب درج',
    'drawer_back'  => 'ضهر درج',
    'drawer_bot'   => 'قاع درج',
    'drawer'       => 'درج',
    'partition'    => 'قاطوع',
    'divider'      => 'قاطوع',
    'upright'      => 'قائم رأسي',
    'rail'         => 'مرايا / عارضة',
    'stretcher'    => 'مرايا تجميع',
    'plinth'       => 'وزرة',
    'toekick'      => 'وزرة',
    'filler'       => 'سدة / فيلر',
    'cladding'     => 'تجليدة',
    'panel'        => 'لوح',
    'frame'        => 'إطار / شاسيه'
  }.freeze

  def self.run_arabic_part_translator
    model = Sketchup.active_model
    roots = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    if roots.empty?
      UI.messagebox('الرجاء تحديد الوحدة أو الوحدات المطلوب ترجمة أسماء قطعها أولاً.')
      return false
    end

    count = 0
    model.start_operation('ترجمة أسماء القطع للعربية - مكتبة محمد عادل', true)
    begin
      walk = lambda do |ent|
        next unless ent && ent.valid?
        if ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)
          raw_name = ent.name.to_s.strip
          raw_name = ent.definition.name.to_s.strip if raw_name.empty? && ent.is_a?(Sketchup::ComponentInstance)
          clean = raw_name.sub(/#\d+\z/, '').strip.downcase

          ARABIC_PART_DICTIONARY.each do |en_kw, ar_label|
            if clean == en_kw || clean.include?(en_kw)
              ent.name = ar_label
              if ent.is_a?(Sketchup::ComponentInstance)
                ent.definition.name = "#{ar_label} (#{ent.definition.entityID})" rescue nil
              end
              ent.set_attribute('dynamic_attributes', '_name', ar_label) rescue nil
              count += 1
              break
            end
          end

          ents = DolaWoodGrainManager.ents_of(ent)
          ents.each { |ch| walk.call(ch) } if ents
        end
      end

      roots.each { |r| walk.call(r) }
      model.commit_operation
      UI.messagebox("✅ تم تعريب وترجمة أسماء (#{count}) قطعة داخل الوحدات المحددة لتظهر بالعربية في الـ Cutting List.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء الترجمة:\n#{e.message}")
      false
    end
  end

  # 6) أداة ترقيم الوحدات التسلسلي (Unit Serial Numbering)
  def self.open_serial_numbering_dialog
    model = Sketchup.active_model
    units = model.selection.grep(Sketchup::ComponentInstance)
    units = model.active_entities.grep(Sketchup::ComponentInstance) if units.empty?

    if units.empty?
      UI.messagebox('لا توجد وحدات في المشهد لترقيمها.')
      return false
    end

    prompts = ['بادئة الترقيم (مثال U أو B):', 'البدء من رقم:', 'إظهار الرقم كنص ثلاثي الأبعاد فوق الوحدة؟']
    defaults = ['U-', 1, 'نعم']
    list = ['', '', 'نعم|لا']
    res = UI.inputbox(prompts, defaults, list, 'ترقيم الوحدات — مكتبة محمد عادل')
    return false unless res

    prefix, start_num, show_label = res
    start_num = [start_num.to_i, 1].max

    # ترتيب الوحدات مكانياً من اليمين لليسار ومن الأسفل للأعلى
    sorted_units = units.sort_by { |u| [u.bounds.min.z.round(1), u.bounds.min.x.round(1), u.bounds.min.y.round(1)] }

    model.start_operation('ترقيم الوحدات - مكتبة محمد عادل', true)
    begin
      sorted_units.each_with_index do |u, idx|
        code = format('%s%02d', prefix.to_s.strip, start_num + idx)
        u.set_attribute('dynamic_attributes', 'cod', code) rescue nil
        u.set_attribute(PREF_NS, 'unit_serial', code) rescue nil
        base_title = u.definition.name.to_s.sub(/\A\[[^\]]+\]\s*/, '')
        u.name = "[#{code}] #{base_title}"

        if show_label == 'نعم'
          pt = Geom::Point3d.new(u.bounds.center.x, u.bounds.min.y, u.bounds.max.z + 4.cm)
          model.active_entities.add_text(code, pt) rescue nil
        end
      end
      model.commit_operation
      UI.messagebox("✅ تم ترقيم (#{sorted_units.length}) وحدة بنجاح بداية من #{prefix}#{format('%02d', start_num)}.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء الترقيم:\n#{e.message}")
      false
    end
  end

  # 7) أداة حفر الليد (LED Groove Tool)
  def self.open_led_groove_dialog
    model = Sketchup.active_model
    sel = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    if sel.empty?
      UI.messagebox('الرجاء تحديد الوحدة أو اللوح المطلوب إضافة مجرى بروفايل الليد (LED Groove) له أولاً.')
      return false
    end

    prompts  = ['عرض مجرى الليد (سم):', 'عمق الحفر (سم):', 'المسافة من الحافة الأمامية (سم):', 'لون إضاءة الليد:']
    defaults = [1.8, 0.8, 4.0, 'أصفر دافئ (Warm 3000K)']
    list     = ['', '', '', 'أصفر دافئ (Warm 3000K)|أبيض نهاري (Daylight 4000K)|أبيض ثلجي (Cool 6500K)']
    res = UI.inputbox(prompts, defaults, list, 'حفر مجرى الليد (LED) — مكتبة محمد عادل')
    return false unless res

    groove_w = res[0].to_f.cm
    groove_d = res[1].to_f.cm
    front_offset = res[2].to_f.cm
    led_tone = res[3].to_s

    led_color =
      if led_tone.include?('ثلجي')
        Sketchup::Color.new(224, 242, 254)
      elsif led_tone.include?('نهاري')
        Sketchup::Color.new(254, 249, 195)
      else
        Sketchup::Color.new(253, 224, 71)
      end

    model.start_operation('إضافة مجرى إضاءة LED - مكتبة محمد عادل', true)
    count = 0
    begin
      led_mat = model.materials['Dola_LED_Light'] || model.materials.add('Dola_LED_Light')
      led_mat.color = led_color

      alu_mat = model.materials['Dola_LED_Aluminum'] || model.materials.add('Dola_LED_Aluminum')
      alu_mat.color = Sketchup::Color.new(60, 68, 82)

      sel.each do |unit|
        next unless unit && unit.valid?
        ents = DolaWoodGrainManager.ents_of(unit)
        next unless ents
        bb = unit.is_a?(Sketchup::ComponentInstance) ? unit.definition.bounds : unit.bounds

        # إنشاء جروب بروفايل الليد أسفل القاعدة الأمامية للوحدة
        grp = ents.add_group
        grp.name = 'مجرى إضاءة LED'
        x1 = bb.min.x + 1.8.cm
        x2 = bb.max.x - 1.8.cm
        next if x2 <= x1

        y_front = bb.min.y + front_offset
        y_back  = y_front + groove_w
        z_bot   = bb.min.z
        z_top   = z_bot + groove_d

        face = grp.entities.add_face(
          Geom::Point3d.new(x1, y_front, z_bot),
          Geom::Point3d.new(x2, y_front, z_bot),
          Geom::Point3d.new(x2, y_back,  z_bot),
          Geom::Point3d.new(x1, y_back,  z_bot)
        )
        if face
          face.material = led_mat
          face.back_material = led_mat
          face.pushpull(-groove_d) rescue nil
        end
        count += 1
      end
      model.commit_operation
      UI.messagebox("✨ تم إنشاء مجرى بروفايل الليد لعدد (#{count}) وحدة بنجاح.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء حفر الليد:\n#{e.message}")
      false
    end
  end

  # 8) أداة تبديل الضلفة (Door Style Switcher)
  def self.open_door_style_dialog
    model = Sketchup.active_model
    sel = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    if sel.empty?
      UI.messagebox('الرجاء تحديد الوحدة أو الضلفة المطلوب تغيير تصميمها أولاً.')
      return false
    end

    prompts  = ['تصميم الضلفة الجديد:', 'عرض إطار الشيكر/الكلاسيك (سم):', 'عمق الحفر الداخلي (مم):']
    defaults = ['شيكر كلاسيك (Shaker Frame)', 6.0, 4.0]
    list     = ['شيكر كلاسيك (Shaker Frame)|ضلفة زجاج بإطار (Glass Door)|ضلفة سادة مودرن (Flat Modern)', '', '']
    res = UI.inputbox(prompts, defaults, list, 'تبديل تصميم الضلفة — مكتبة محمد عادل')
    return false unless res

    style_name, frame_cm, recess_mm = res
    frame_w  = [frame_cm.to_f, 3.0].max.cm
    recess_d = [recess_mm.to_f, 2.0].max.mm

    # البحث عن الضلف داخل المحدد
    doors = []
    walk = lambda do |ent|
      next unless ent && ent.valid?
      if ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)
        nm = DolaWoodGrainManager.entity_display_name(ent).downcase
        if nm.include?('ضلف') || nm.include?('ضل') || nm.include?('باب') || nm.include?('door')
          doors << ent if DolaWoodGrainManager.leaf_wooden_board?(ent)
        end
        ents = DolaWoodGrainManager.ents_of(ent)
        ents.each { |ch| walk.call(ch) } if ents
      end
    end
    sel.each { |s| walk.call(s) }
    doors = sel.select { |s| DolaWoodGrainManager.leaf_wooden_board?(s) } if doors.empty?

    if doors.empty?
      UI.messagebox('لم يتم العثور على ضلف داخل العنصر المحدد.')
      return false
    end

    model.start_operation('تبديل تصميم الضلفة - مكتبة محمد عادل', true)
    modified = 0
    begin
      glass_mat = nil
      if style_name.include?('زجاج')
        glass_mat = model.materials['Dola_Door_Glass'] || model.materials.add('Dola_Door_Glass')
        glass_mat.color = Sketchup::Color.new(30, 41, 59)
        glass_mat.alpha = 0.55
      end

      doors.each do |door|
        door.make_unique if door.is_a?(Sketchup::ComponentInstance) && door.definition.count_used_instances > 1
        ents = DolaWoodGrainManager.ents_of(door)
        next unless ents

        # إزالة أي تشكيل شيكر سابق إن وجد
        ents.grep(Sketchup::Group).each do |g|
          g.erase! if g.name == 'Dola_Door_Profile_Insert'
        end

        unless style_name.include?('سادة')
          bb = door.is_a?(Sketchup::ComponentInstance) ? door.definition.bounds : door.bounds
          dims = [
            [:x, bb.width.to_f,  bb.min.x, bb.max.x],
            [:y, bb.height.to_f, bb.min.y, bb.max.y],
            [:z, bb.depth.to_f,  bb.min.z, bb.max.z]
          ].sort_by { |d| d[1] }

          # الأصغر هو السمك، والآخران هما عرض وارتفاع الضلفة
          thick_axis = dims[0][0]
          a1 = dims[1]
          a2 = dims[2]

          if a1[1] > (frame_w * 2.2) && a2[1] > (frame_w * 2.2)
            grp = ents.add_group
            grp.name = 'Dola_Door_Profile_Insert'
            u_min = a1[2] + frame_w
            u_max = a1[3] - frame_w
            v_min = a2[2] + frame_w
            v_max = a2[3] - frame_w
            t_pos = dims[0][2]

            mk_pt = lambda do |u, v, t|
              coords = { a1[0] => u, a2[0] => v, thick_axis => t }
              Geom::Point3d.new(coords[:x], coords[:y], coords[:z])
            end

            f = grp.entities.add_face(
              mk_pt.call(u_min, v_min, t_pos),
              mk_pt.call(u_max, v_min, t_pos),
              mk_pt.call(u_max, v_max, t_pos),
              mk_pt.call(u_min, v_max, t_pos)
            )
            if f
              if glass_mat
                f.material = glass_mat
                f.back_material = glass_mat
              elsif door.material
                f.material = door.material
              end
              f.pushpull(recess_d) rescue nil
            end
          end
        end
        modified += 1
      end
      model.commit_operation
      UI.messagebox("✨ تم تحديث تصميم (#{modified}) ضلفة إلى «#{style_name}» بنجاح.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء تعديل الضلفة:\n#{e.message}")
      false
    end
  end

  # 9) نافذة مستويات وخامات المطبخ (Kitchen Materials & Wood Grain Textures)
  @kitchen_materials_dlg = nil



  # ============================================================================
  #  9) نافذة «مستويات وخامات المطبخ» الشاملة (إدارة المستويات + تغيير أسماء وألوان الخامات والـ CutList)
  # ============================================================================
  KITCHEN_MATERIAL_PRESETS = [
    { :id => 'hpl_oak',        :name => 'HPL أوك طبيعي (ثمرة خشب)',     :rgb => [194, 145, 95],  :grained => true,  :kind => 'HPL' },
    { :id => 'hpl_walnut',     :name => 'HPL جوز تركي داكن (ثمرة خشب)',  :rgb => [118, 78, 52],   :grained => true,  :kind => 'HPL' },
    { :id => 'hpl_2side_ash',  :name => 'HPL وشين قشرة أرو (ثمرة خشب)',  :rgb => [212, 175, 130], :grained => true,  :kind => 'HPL وشين' },
    { :id => 'hpl_2side_teak', :name => 'HPL وشين تك دافئ (ثمرة خشب)',   :rgb => [168, 112, 68],  :grained => true,  :kind => 'HPL وشين' },
    { :id => 'wood_back',      :name => 'ضهر خشابي 6مم (ثمرة خشب)',     :rgb => [178, 132, 88],  :grained => true,  :kind => 'ضهر خشابي' },
    { :id => 'mdf_white',      :name => 'كونتر / MDF أبيض سادة',        :rgb => [244, 246, 249], :grained => false, :kind => 'سادة' },
    { :id => 'mdf_beige',      :name => 'شاسيه كافيه / بيج ناعم سادة',  :rgb => [226, 214, 198], :grained => false, :kind => 'سادة' },
    { :id => 'mdf_anthracite', :name => 'أنتراسيت رمادي فحمي مودرن',   :rgb => [55, 65, 81],    :grained => false, :kind => 'سادة' },
    { :id => 'mdf_navy',       :name => 'كحلي ملكي (مكتبة محمد عادل)',   :rgb => [30, 41, 95],    :grained => false, :kind => 'سادة' },
    { :id => 'mdf_sage',       :name => 'أخضر سيج مودرن سادة',          :rgb => [115, 142, 126], :grained => false, :kind => 'سادة' }
  ].freeze

  def self.collect_model_materials_payload
    model = Sketchup.active_model
    mats = []
    model.materials.each do |m|
      next unless m && m.valid?
      c = m.color || Sketchup::Color.new(200, 200, 200)
      hex = format('#%02x%02x%02x', c.red, c.green, c.blue)
      has_tex = !m.texture.nil?
      override = m.get_attribute(GRAIN_DICT, 'grained_override', nil)
      is_grained =
        if override == 'true'
          true
        elsif override == 'false'
          false
        else
          has_tex || DolaWoodGrainManager::WOOD_GRAIN_KEYWORDS.any? { |kw| "#{m.display_name} #{m.name}".downcase.include?(kw) }
        end
      kind = m.get_attribute(GRAIN_DICT, 'material_kind', nil).to_s
      if kind.empty?
        nm_low = "#{m.display_name} #{m.name}".downcase
        kind = if nm_low.include?('وشين')
                 'HPL وشين'
               elsif nm_low.include?('ضهر') || nm_low.include?('ظهر')
                 'ضهر خشابي'
               elsif is_grained
                 'HPL'
               else
                 'سادة'
               end
      end
      mats << {
        'raw_name'     => m.name.to_s,
        'display_name' => m.display_name.to_s,
        'hex'          => hex,
        'has_texture'  => has_tex,
        'grained'      => is_grained,
        'kind'         => kind
      }
    end
    mats
  rescue
    []
  end

  def self.refresh_kitchen_materials_dialog_if_open
    return false unless @kitchen_materials_dlg && @kitchen_materials_dlg.visible?
    mats_json = collect_model_materials_payload.to_json
    @kitchen_materials_dlg.execute_script("window.receiveModelMaterials(#{mats_json});") rescue nil
    true
  rescue
    false
  end

  def self.open_kitchen_materials_tool
    if @kitchen_materials_dlg && @kitchen_materials_dlg.visible?
      refresh_kitchen_materials_dialog_if_open
      @kitchen_materials_dlg.bring_to_front rescue nil
      return true
    end

    @kitchen_materials_dlg = UI::HtmlDialog.new({
      :dialog_title    => 'مستويات وخامات المطبخ وتعديل الأسماء والألوان — مكتبة محمد عادل',
      :preferences_key => 'DolaKitchenMaterials_v3',
      :scrollable      => false,
      :resizable       => true,
      :width           => 540,
      :height          => 690,
      :style           => UI::HtmlDialog::STYLE_DIALOG
    })

    presets_json = KITCHEN_MATERIAL_PRESETS.to_json
    mats_json    = collect_model_materials_payload.to_json

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 13px;
            font-family: 'Tajawal', sans-serif;
            background: linear-gradient(160deg, #1e1b4b 0%, #0f172a 100%);
            color: #f8fafc;
            height: 100vh;
            display: flex;
            flex-direction: column;
            gap: 10px;
            overflow: hidden;
          }
          .head-card {
            background: rgba(15, 23, 42, 0.88);
            border: 1px solid rgba(56, 189, 248, 0.35);
            border-radius: 14px;
            padding: 11px 14px;
            display: flex;
            align-items: center;
            justify-content: space-between;
          }
          .head-card h2 { margin: 0 0 3px; font-size: 16px; color: #38bdf8; }
          .head-card p  { margin: 0; font-size: 11.5px; color: #cbd5e1; }
          .tabs-row {
            display: grid;
            grid-template-columns: 1fr 1fr 1fr;
            gap: 6px;
            background: rgba(15, 23, 42, 0.85);
            padding: 4px;
            border-radius: 11px;
            border: 1px solid rgba(255, 255, 255, 0.12);
          }
          .tab-b {
            background: transparent;
            border: none;
            color: #94a3b8;
            padding: 7px 8px;
            border-radius: 8px;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 800;
            cursor: pointer;
          }
          .tab-b.active {
            background: linear-gradient(135deg, #0284c7 0%, #1d4ed8 100%);
            color: #ffffff;
          }
          .scroll-area {
            flex: 1;
            overflow-y: auto;
            display: flex;
            flex-direction: column;
            gap: 10px;
            padding-left: 3px;
          }
          .scroll-area::-webkit-scrollbar { width: 5px; }
          .scroll-area::-webkit-scrollbar-thumb { background: rgba(56, 189, 248, 0.35); border-radius: 99px; }
          .box-card {
            background: rgba(30, 41, 59, 0.72);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 13px;
            padding: 11px;
            display: flex;
            flex-direction: column;
            gap: 8px;
          }
          .box-title {
            font-size: 12.5px;
            font-weight: 800;
            color: #fbbf24;
            display: flex;
            align-items: center;
            justify-content: space-between;
          }
          select, input[type="text"], input[type="number"] {
            width: 100%;
            padding: 7px 10px;
            border-radius: 8px;
            background: #0f172a;
            border: 1px solid rgba(56, 189, 248, 0.38);
            color: #fff;
            font-family: 'Tajawal', sans-serif;
            font-size: 12.5px;
            font-weight: 700;
            outline: none;
          }
          input[type="color"] {
            width: 44px;
            height: 34px;
            padding: 2px;
            border-radius: 8px;
            background: #0f172a;
            border: 1px solid rgba(255, 255, 255, 0.3);
            cursor: pointer;
          }
          .presets-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 8px;
          }
          .preset-card {
            background: rgba(15, 23, 42, 0.85);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 11px;
            padding: 8px;
            cursor: pointer;
            display: flex;
            flex-direction: column;
            gap: 6px;
            transition: all 0.16s;
          }
          .preset-card:hover, .preset-card.active {
            border-color: #38bdf8;
            background: rgba(2, 132, 199, 0.24);
          }
          .swatch {
            height: 32px;
            border-radius: 7px;
            border: 1px solid rgba(255, 255, 255, 0.25);
            position: relative;
            overflow: hidden;
          }
          .swatch-badge {
            position: absolute;
            bottom: 3px; left: 5px;
            font-size: 9.5px;
            font-weight: 800;
            background: rgba(15, 23, 42, 0.82);
            color: #fbbf24;
            padding: 1px 6px;
            border-radius: 5px;
          }
          .preset-title { font-size: 11.5px; font-weight: 700; color: #f1f5f9; }
          .custom-row {
            display: grid;
            grid-template-columns: 1.4fr auto 1fr;
            gap: 8px;
            align-items: center;
          }
          .mat-item-row {
            background: rgba(15, 23, 42, 0.82);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 11px;
            padding: 9px;
            display: flex;
            flex-direction: column;
            gap: 7px;
          }
          .mat-top-line {
            display: grid;
            grid-template-columns: auto 1fr auto;
            gap: 8px;
            align-items: center;
          }
          .mat-bot-line {
            display: grid;
            grid-template-columns: 1fr auto auto;
            gap: 7px;
            align-items: center;
          }
          .small-btn {
            background: rgba(56, 189, 248, 0.16);
            border: 1px solid rgba(56, 189, 248, 0.45);
            color: #38bdf8;
            padding: 6px 10px;
            border-radius: 8px;
            font-family: 'Tajawal', sans-serif;
            font-size: 11.5px;
            font-weight: 800;
            cursor: pointer;
            white-space: nowrap;
          }
          .small-btn:hover { background: #38bdf8; color: #0f172a; }
          .save-mat-btn {
            background: linear-gradient(135deg, #10b981 0%, #047857 100%);
            border: 1px solid #34d399;
            color: #fff;
            padding: 6px 12px;
            border-radius: 8px;
            font-family: 'Tajawal', sans-serif;
            font-size: 11.5px;
            font-weight: 800;
            cursor: pointer;
            white-space: nowrap;
          }
          .apply-btn {
            background: linear-gradient(135deg, #0284c7 0%, #0369a1 100%);
            border: 1px solid #38bdf8;
            color: #fff;
            padding: 10px;
            border-radius: 11px;
            font-family: 'Tajawal', sans-serif;
            font-size: 13.5px;
            font-weight: 800;
            cursor: pointer;
          }
        </style>
      </head>
      <body oncontextmenu="return false;">
        <div class="head-card">
          <div>
            <h2>🎨 مستويات وخامات المطبخ وتعديل الأسماء والألوان</h2>
            <p>تخصيص خامات المستويات + تعديل أسماء وألوان خامات المشروع للـ OpenCutList</p>
          </div>
          <button class="small-btn" onclick="requestMatsRefresh()">🔄 تحديث</button>
        </div>

        <div class="tabs-row">
          <button type="button" id="mTab1" class="tab-b active" onclick="switchMatTab('levels')">🏢 توزيع خامات المستويات</button>
          <button type="button" id="mTab2" class="tab-b" onclick="switchMatTab('editor')">✏️ تعديل أسماء وألوان الخامات</button>
          <button type="button" id="mTab3" class="tab-b" onclick="switchMatTab('create')">➕ إنشاء خامة جديدة</button>
        </div>

        <div id="levelsView" class="scroll-area">
          <div class="box-card">
            <div class="box-title">
              <span>1) اختر المستوى / الجزء المستهدف في المطبخ:</span>
            </div>
            <select id="targetPartSelect">
              <option value="all_parts">جميع قطع الوحدات المحددة (أو المطبخ بالكامل)</option>
              <option value="level_base">المستوى السفلي فقط (الوحدات السفلية Base Units)</option>
              <option value="level_upper1">المستوى العلوي الأول فقط (Upper Level 1)</option>
              <option value="level_upper2">المستوى العلوي الثاني / البانوهات (Upper Level 2)</option>
              <option value="level_tall">الدواليب الطويلة فقط (Tall Units / البانتري)</option>
              <option value="doors_only">الضلف ووشوش الأدراج والتجاليد الخارجية فقط</option>
              <option value="carcass_only">الشاسيه الداخلي فقط (الأجناب + الأرفف + القواطيع)</option>
              <option value="backs_only">الضهر فقط (تحويل أو تلوين الضهر الخشابي 6مم)</option>
              <option value="plinth_only">الوزرة السفلية فقط (السوكلو / Plinth)</option>
            </select>
          </div>

          <div class="box-card">
            <div class="box-title">
              <span>2) اختر قالب الخامة أو خصص الاسم واللون قبل التطبيق:</span>
            </div>
            <div class="presets-grid" id="presetsGrid"></div>
          </div>

          <div class="box-card">
            <div class="box-title">
              <span>3) تخصيص اسم ولون ونوع الخامة المختارة (يظهر في OpenCutList):</span>
            </div>
            <div class="custom-row">
              <input type="text" id="customMatName" placeholder="اسم الخامة في التقطيع (مثلاً: HPL 1055 وشين)">
              <input type="color" id="customMatColor" value="#c2915f" title="اختر لون الخامة">
              <select id="customMatKind">
                <option value="HPL">HPL (بثمرة خشب)</option>
                <option value="HPL وشين">HPL وشين (بثمرة خشب)</option>
                <option value="ضهر خشابي">ضهر خشابي (بثمرة خشب)</option>
                <option value="سادة">كونتر / MDF سادة (بدون ثمرة)</option>
              </select>
            </div>
          </div>

          <button class="apply-btn" onclick="applySelectedMaterial()">✨ تطبيق الخامة بالاسم واللون المحددين</button>
        </div>

        <div id="editorView" class="scroll-area" style="display:none;">
          <div class="box-card">
            <div class="box-title">
              <span>✏️ خامات المشروع الحالية (عدّل الاسم أو اللون أو النوع ثم اضغط حفظ):</span>
            </div>
            <div id="modelMatsList" style="display:flex;flex-direction:column;gap:8px;"></div>
          </div>
        </div>

        <div id="createView" class="scroll-area" style="display:none;">
          <div class="box-card">
            <div class="box-title"><span>➕ إضافة خامة جديدة للمشروع:</span></div>
            <label style="font-size:12px;">اسم الخامة الجديد (كما سيظهر في سكتش أب والـ CutList):</label>
            <input type="text" id="newMatName" placeholder="مثال: HPL 2040 وشين قشرة أرو">

            <div style="display:grid;grid-template-columns:auto 1fr;gap:10px;align-items:center;margin-top:4px;">
              <input type="color" id="newMatColor" value="#b88655">
              <select id="newMatKind">
                <option value="HPL">HPL وجه واحد (بثمرة خشب)</option>
                <option value="HPL وشين">HPL وشين (بثمرة خشب)</option>
                <option value="ضهر خشابي">ضهر خشابي 6مم (بثمرة خشب)</option>
                <option value="سادة">خامة سادة بدون ثمرة (أبيض / ألوان)</option>
              </select>
            </div>

            <div style="display:flex;gap:8px;margin-top:8px;">
              <button type="button" class="apply-btn" style="flex:1;" onclick="createNewMaterial(false)">➕ إنشاء الخامة في الموديل</button>
              <button type="button" class="small-btn" onclick="createNewMaterial(true)">📁 إنشاء مع اختيار صورة نقشة من الجهاز</button>
            </div>
          </div>
        </div>

        <script>
          const PRESETS = #{presets_json};
          let modelMaterials = #{mats_json};
          let selectedId = PRESETS[0].id;

          function esc(s) {
            return String(s == null ? '' : s)
              .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
          }

          function rgbToHex(r, g, b) {
            return '#' + [r, g, b].map(x => Math.max(0, Math.min(255, Number(x)||0)).toString(16).padStart(2, '0')).join('');
          }

          function switchMatTab(tab) {
            document.getElementById('mTab1').classList.toggle('active', tab === 'levels');
            document.getElementById('mTab2').classList.toggle('active', tab === 'editor');
            document.getElementById('mTab3').classList.toggle('active', tab === 'create');
            document.getElementById('levelsView').style.display = (tab === 'levels') ? 'flex' : 'none';
            document.getElementById('editorView').style.display = (tab === 'editor') ? 'flex' : 'none';
            document.getElementById('createView').style.display = (tab === 'create') ? 'flex' : 'none';
            if (tab === 'editor') renderModelMatsEditor();
          }

          window.receiveModelMaterials = function(list) {
            modelMaterials = Array.isArray(list) ? list : [];
            renderModelMatsEditor();
          };

          function renderPresets() {
            const grid = document.getElementById('presetsGrid');
            grid.innerHTML = PRESETS.map(p => {
              const [r, g, b] = p.rgb;
              const active = (p.id === selectedId) ? 'active' : '';
              const bgCss  = p.grained
                ? `repeating-linear-gradient(90deg, rgb(${r},${g},${b}) 0px, rgb(${Math.max(r-18,0)},${Math.max(g-18,0)},${Math.max(b-18,0)}) 4px, rgb(${r},${g},${b}) 8px)`
                : `rgb(${r},${g},${b})`;
              return `
                <div class="preset-card ${active}" onclick="selectPreset('${p.id}')">
                  <div class="swatch" style="background:${bgCss};">
                    <span class="swatch-badge">${esc(p.kind || (p.grained ? 'ثمرة خشب' : 'سادة'))}</span>
                  </div>
                  <div class="preset-title">${esc(p.name)}</div>
                </div>
              `;
            }).join('');
          }

          function selectPreset(id) {
            selectedId = id;
            const p = PRESETS.find(x => x.id === id);
            if (p) {
              document.getElementById('customMatName').value  = p.name;
              document.getElementById('customMatColor').value = rgbToHex(p.rgb[0], p.rgb[1], p.rgb[2]);
              document.getElementById('customMatKind').value  = p.kind || (p.grained ? 'HPL' : 'سادة');
            }
            renderPresets();
          }

          function applySelectedMaterial() {
            const payload = {
              preset_id: selectedId,
              target: document.getElementById('targetPartSelect').value,
              custom_name: document.getElementById('customMatName').value.trim(),
              custom_hex: document.getElementById('customMatColor').value,
              custom_kind: document.getElementById('customMatKind').value
            };
            if (window.sketchup && window.sketchup.apply_kitchen_material) {
              window.sketchup.apply_kitchen_material(JSON.stringify(payload));
            }
          }

          function renderModelMatsEditor() {
            const box = document.getElementById('modelMatsList');
            if (!box) return;
            if (!modelMaterials || modelMaterials.length === 0) {
              box.innerHTML = `<div style="padding:16px;text-align:center;color:#94a3b8;">لا توجد خامات في الموديل حالياً.</div>`;
              return;
            }
            box.innerHTML = modelMaterials.map((m, idx) => `
              <div class="mat-item-row" data-raw="${esc(m.raw_name)}">
                <div class="mat-top-line">
                  <input type="color" class="edit-mat-hex" value="${esc(m.hex || '#cccccc')}" title="تغيير لون الخامة">
                  <input type="text" class="edit-mat-name" value="${esc(m.display_name)}" placeholder="اسم الخامة...">
                  <button type="button" class="save-mat-btn" onclick="saveSingleMatEdit(${idx})">💾 حفظ</button>
                </div>
                <div class="mat-bot-line">
                  <select class="edit-mat-kind">
                    <option value="HPL" ${m.kind === 'HPL' ? 'selected' : ''}>🪵 HPL (بثمرة خشب)</option>
                    <option value="HPL وشين" ${m.kind === 'HPL وشين' ? 'selected' : ''}>🪵 HPL وشين (بثمرة خشب)</option>
                    <option value="ضهر خشابي" ${m.kind === 'ضهر خشابي' ? 'selected' : ''}>🪵 ضهر خشابي (بثمرة خشب)</option>
                    <option value="سادة" ${m.kind === 'سادة' ? 'selected' : ''}>🎨 خامة سادة (بدون ثمرة)</option>
                  </select>
                  <button type="button" class="small-btn" onclick="pickTextureForMat(${idx})" title="اختيار صورة نقشة خشب من الجهاز">📁 صورة نقشة</button>
                  <button type="button" class="small-btn" onclick="applyExistingMatToTarget(${idx})" title="تطبيق هذه الخامة على المستوى المختار في التبويب الأول">🎯 تطبيق على المستوى</button>
                </div>
              </div>
            `).join('');
          }

          function saveSingleMatEdit(idx) {
            const rows = document.querySelectorAll('#modelMatsList .mat-item-row');
            const row = rows[idx];
            if (!row) return;
            const rawName = row.getAttribute('data-raw');
            const newName = row.querySelector('.edit-mat-name').value.trim();
            const newHex  = row.querySelector('.edit-mat-hex').value;
            const newKind = row.querySelector('.edit-mat-kind').value;
            if (window.sketchup && window.sketchup.update_existing_material) {
              window.sketchup.update_existing_material(JSON.stringify({
                raw_name: rawName,
                new_name: newName,
                hex: newHex,
                kind: newKind,
                pick_image: false
              }));
            }
          }

          function pickTextureForMat(idx) {
            const rows = document.querySelectorAll('#modelMatsList .mat-item-row');
            const row = rows[idx];
            if (!row) return;
            const rawName = row.getAttribute('data-raw');
            const newName = row.querySelector('.edit-mat-name').value.trim();
            const newHex  = row.querySelector('.edit-mat-hex').value;
            const newKind = row.querySelector('.edit-mat-kind').value;
            if (window.sketchup && window.sketchup.update_existing_material) {
              window.sketchup.update_existing_material(JSON.stringify({
                raw_name: rawName,
                new_name: newName,
                hex: newHex,
                kind: newKind,
                pick_image: true
              }));
            }
          }

          function applyExistingMatToTarget(idx) {
            const m = modelMaterials[idx];
            if (!m) return;
            const target = document.getElementById('targetPartSelect').value;
            if (window.sketchup && window.sketchup.apply_existing_material_to_scope) {
              window.sketchup.apply_existing_material_to_scope(JSON.stringify({
                raw_name: m.raw_name,
                target: target
              }));
            }
          }

          function createNewMaterial(pickImage) {
            const name = document.getElementById('newMatName').value.trim();
            const hex  = document.getElementById('newMatColor').value;
            const kind = document.getElementById('newMatKind').value;
            if (!name) {
              alert('برجاء كتابة اسم الخامة الجديد أولاً.');
              return;
            }
            if (window.sketchup && window.sketchup.create_custom_material) {
              window.sketchup.create_custom_material(JSON.stringify({
                name: name,
                hex: hex,
                kind: kind,
                pick_image: !!pickImage
              }));
            }
          }

          function requestMatsRefresh() {
            if (window.sketchup && window.sketchup.refresh_model_materials) {
              window.sketchup.refresh_model_materials();
            }
          }

          selectPreset(PRESETS[0].id);
          renderModelMatsEditor();
        </script>
      </body>
      </html>
    HTML

    @kitchen_materials_dlg.set_html(html)

    @kitchen_materials_dlg.add_action_callback('apply_kitchen_material') do |_ctx, json_str|
      data = JSON.parse(json_str.to_s) rescue {}
      apply_kitchen_material_preset!(
        data['preset_id'],
        data['target'],
        data['custom_name'],
        data['custom_hex'],
        data['custom_kind']
      )
    end

    @kitchen_materials_dlg.add_action_callback('update_existing_material') do |_ctx, json_str|
      data = JSON.parse(json_str.to_s) rescue {}
      update_model_material_properties!(data)
    end

    @kitchen_materials_dlg.add_action_callback('apply_existing_material_to_scope') do |_ctx, json_str|
      data = JSON.parse(json_str.to_s) rescue {}
      apply_existing_model_material_to_scope!(data['raw_name'], data['target'])
    end

    @kitchen_materials_dlg.add_action_callback('create_custom_material') do |_ctx, json_str|
      data = JSON.parse(json_str.to_s) rescue {}
      create_custom_model_material!(data)
    end

    @kitchen_materials_dlg.add_action_callback('refresh_model_materials') do |_ctx|
      refresh_kitchen_materials_dialog_if_open
    end

    @kitchen_materials_dlg.show
    true
  end

  def self.parse_hex_rgb(hex_str, fallback = [194, 145, 95])
    s = hex_str.to_s.strip.sub(/\A#/, '')
    return fallback unless s =~ /\A[0-9A-Fa-f]{6}\z/
    [s[0..1].to_i(16), s[2..3].to_i(16), s[4..5].to_i(16)]
  rescue
    fallback
  end

  def self.filter_units_by_kitchen_level(roots, target_scope)
    scope = target_scope.to_s
    return roots unless %w[level_base level_upper1 level_upper2 level_tall].include?(scope)

    selected = roots.select do |u|
      next false unless u && u.valid?
      bb = u.bounds
      z_min_cm = bb.min.z.to_f * 2.54
      h_cm     = bb.height.to_f * 2.54
      nm       = "#{u.name} #{u.respond_to?(:definition) ? u.definition.name : ''}".downcase

      case scope
      when 'level_tall'
        h_cm >= 175.0 || nm.include?('دولاب') || nm.include?('بانتري') || nm.include?('ثلاجة') || nm.include?('فرن')
      when 'level_base'
        h_cm < 175.0 && z_min_cm < 95.0
      when 'level_upper1'
        h_cm < 175.0 && z_min_cm >= 95.0 && z_min_cm < 195.0
      when 'level_upper2'
        h_cm < 175.0 && z_min_cm >= 195.0
      else
        true
      end
    end
    selected.empty? ? roots : selected
  end

  def self.filter_boards_by_part_scope(boards, target_scope)
    scope = target_scope.to_s
    return boards if %w[all_parts level_base level_upper1 level_upper2 level_tall].include?(scope)

    filtered = boards.select do |b|
      nm = DolaWoodGrainManager.entity_display_name(b[:entity]).downcase
      case scope
      when 'doors_only'
        nm.include?('ضلف') || nm.include?('ضل') || nm.include?('باب') || nm.include?('وش') || nm.include?('تجليد') || nm.include?('door') || nm.include?('front')
      when 'backs_only'
        nm.include?('ضهر') || nm.include?('ظهر') || nm.include?('back')
      when 'plinth_only'
        nm.include?('وزر') || nm.include?('سوكلو') || nm.include?('plinth') || nm.include?('kick')
      when 'carcass_only'
        !(nm.include?('ضلف') || nm.include?('باب') || nm.include?('door') || nm.include?('وش') || nm.include?('ضهر') || nm.include?('ظهر'))
      else
        true
      end
    end
    filtered.empty? ? boards : filtered
  end

  def self.configure_material_grain_and_color!(mat, rgb, kind_str, pick_image = false)
    return unless mat && mat.valid?
    r, g, b = rgb
    mat.color = Sketchup::Color.new(r, g, b)
    grained = (kind_str.to_s != 'سادة')
    mat.set_attribute(GRAIN_DICT, 'material_kind', kind_str.to_s)
    mat.set_attribute(GRAIN_DICT, 'grained_override', grained ? 'true' : 'false')

    if pick_image
      img_path = UI.openpanel('اختر صورة نقشة الخشب (PNG / JPG)', '', 'Image Files|*.png;*.jpg;*.jpeg;||')
      if img_path && File.exist?(img_path)
        mat.texture = img_path
        mat.texture.size = [40.cm, 40.cm] rescue nil
      end
    elsif grained
      DolaWoodGrainManager.ensure_procedural_wood_texture!(mat)
    else
      mat.texture = nil rescue nil
    end
  end

  def self.update_model_material_properties!(data)
    model = Sketchup.active_model
    raw_name = data['raw_name'].to_s
    mat = model.materials[raw_name] || model.materials.find { |m| m.display_name.to_s == raw_name }
    unless mat
      UI.messagebox("لم يتم العثور على الخامة المطلوبة في الموديل.")
      return false
    end

    new_name = data['new_name'].to_s.strip
    rgb      = parse_hex_rgb(data['hex'], [200, 200, 200])
    kind_str = data['kind'].to_s.strip
    kind_str = 'HPL' if kind_str.empty?

    model.start_operation('تعديل اسم ولون الخامة - مكتبة محمد عادل', true)
    begin
      if !new_name.empty? && new_name != mat.name && new_name != mat.display_name
        mat.name = new_name rescue nil
      end
      configure_material_grain_and_color!(mat, rgb, kind_str, data['pick_image'] == true)
      model.commit_operation
      model.active_view.invalidate
      refresh_kitchen_materials_dialog_if_open
      UI.messagebox("✅ تم تحديث الخامة إلى «#{mat.display_name}» (#{kind_str}) بنجاح!")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("تعذر تحديث الخامة:\n#{e.message}")
      false
    end
  end

  def self.create_custom_model_material!(data)
    model = Sketchup.active_model
    name = data['name'].to_s.strip
    return false if name.empty?
    rgb  = parse_hex_rgb(data['hex'], [185, 138, 88])
    kind = data['kind'].to_s.strip
    kind = 'HPL' if kind.empty?

    model.start_operation('إنشاء خامة جديدة - مكتبة محمد عادل', true)
    begin
      mat = model.materials[name] || model.materials.add(name)
      configure_material_grain_and_color!(mat, rgb, kind, data['pick_image'] == true)
      model.commit_operation
      refresh_kitchen_materials_dialog_if_open
      UI.messagebox("✨ تم إنشاء الخامة «#{mat.display_name}» (#{kind}) وإضافتها للمشروع بنجاح!")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("تعذر إنشاء الخامة:\n#{e.message}")
      false
    end
  end

  def self.apply_existing_model_material_to_scope!(raw_name, target_scope)
    model = Sketchup.active_model
    mat = model.materials[raw_name.to_s] || model.materials.find { |m| m.display_name.to_s == raw_name.to_s }
    unless mat
      UI.messagebox('لم يتم العثور على الخامة في الموديل.')
      return false
    end

    roots = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    roots = model.active_entities.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) } if roots.empty?
    roots = filter_units_by_kitchen_level(roots, target_scope)
    boards = DolaWoodGrainManager.collect_wooden_boards(roots, false)
    filtered = filter_boards_by_part_scope(boards, target_scope)

    if filtered.empty?
      UI.messagebox('لم يتم العثور على قطع مطابقة لتطبيق الخامة عليها.')
      return false
    end

    is_grained = DolaWoodGrainManager.has_wood_grain_material?(filtered.first[:entity], mat)
    model.start_operation('تطبيق خامة على المستوى - مكتبة محمد عادل', true)
    begin
      filtered.each do |item|
        ent = item[:entity]
        next unless ent && ent.valid?
        ent.material = mat
        DolaWoodGrainManager.set_part_grain!(ent, :vertical_z, item[:parent_tr], mat, true) if is_grained
      end
      model.commit_operation
      model.active_view.invalidate
      UI.messagebox("✅ تم تطبيق الخامة «#{mat.display_name}» على (#{filtered.length}) قطعة بنجاح!")
      true
    rescue => e
      model.abort_operation rescue nil
      false
    end
  end

  def self.apply_kitchen_material_preset!(preset_id, target_scope, custom_name = nil, custom_hex = nil, custom_kind = nil)
    preset = KITCHEN_MATERIAL_PRESETS.find { |p| p[:id] == preset_id.to_s } || KITCHEN_MATERIAL_PRESETS.first
    model  = Sketchup.active_model
    roots  = model.selection.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
    roots  = model.active_entities.to_a.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) } if roots.empty?

    if roots.empty?
      UI.messagebox('لا توجد وحدات في المشهد لتطبيق الخامة عليها.')
      return false
    end

    level_roots = filter_units_by_kitchen_level(roots, target_scope)
    boards      = DolaWoodGrainManager.collect_wooden_boards(level_roots, false)
    filtered    = filter_boards_by_part_scope(boards, target_scope)

    final_name = custom_name.to_s.strip.empty? ? preset[:name] : custom_name.to_s.strip
    final_rgb  = custom_hex.to_s.strip.empty? ? preset[:rgb] : parse_hex_rgb(custom_hex, preset[:rgb])
    final_kind = custom_kind.to_s.strip.empty? ? (preset[:kind] || (preset[:grained] ? 'HPL' : 'سادة')) : custom_kind.to_s.strip
    is_grained = (final_kind != 'سادة')

    model.start_operation('تطبيق خامات المطبخ - مكتبة محمد عادل', true)
    begin
      mat = model.materials[final_name] || model.materials.add(final_name)
      configure_material_grain_and_color!(mat, final_rgb, final_kind, false)

      filtered.each do |item|
        ent = item[:entity]
        next unless ent && ent.valid?
        ent.material = mat
        if is_grained
          DolaWoodGrainManager.set_part_grain!(ent, :vertical_z, item[:parent_tr], mat, true)
        end
      end
      model.commit_operation
      model.active_view.invalidate
      refresh_kitchen_materials_dialog_if_open
      UI.messagebox("✅ تم تطبيق الخامة «#{final_name}» (#{final_kind}) على (#{filtered.length}) قطعة بنجاح#{is_grained ? ' مع ضبط الثمرة بالطول (Z)' : ''}.")
      true
    rescue => e
      model.abort_operation rescue nil
      UI.messagebox("حدث خطأ أثناء تطبيق الخامة:\n#{e.message}")
      false
    end
  end

  # 10) نافذة تقرير الوحدات التفصيلي (Units Report Dialog)
  @units_report_dlg = nil

  def self.collect_project_units_summary
    model = Sketchup.active_model
    insts = model.active_entities.grep(Sketchup::ComponentInstance)
    rows = []
    insts.each_with_index do |u, idx|
      next unless u && u.valid?
      bb = u.bounds
      w_cm = (bb.width.to_f * 2.54).round(1)
      d_cm = (bb.depth.to_f * 2.54).round(1)
      h_cm = (bb.height.to_f * 2.54).round(1)
      next if [w_cm, d_cm, h_cm].max < 8.0

      code = u.get_attribute('dynamic_attributes', 'cod', nil) ||
             u.get_attribute(PREF_NS, 'unit_serial', nil) ||
             format('U-%02d', idx + 1)
      title = resolve_library_unit_display_name(u)

      boards = DolaWoodGrainManager.collect_wooden_boards([u], true)
      rows << {
        'index'        => idx + 1,
        'code'         => code.to_s,
        'name'         => title,
        'width_cm'     => w_cm,
        'depth_cm'     => d_cm,
        'height_cm'    => h_cm,
        'grained_parts'=> boards.length
      }
    end
    rows
  end

  def self.open_units_report_dialog
    rows = collect_project_units_summary
    dlg = UI::HtmlDialog.new({
      :dialog_title    => 'تقرير وحدات المشروع — مكتبة محمد عادل',
      :preferences_key => 'DolaUnitsReport_v2',
      :scrollable      => true,
      :resizable       => true,
      :width           => 780,
      :height          => 580,
      :style           => UI::HtmlDialog::STYLE_DIALOG
    })

    rows_json = rows.to_json

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 18px;
            font-family: 'Tajawal', sans-serif;
            background: #0f172a;
            color: #f8fafc;
          }
          .top-bar {
            display: flex;
            align-items: center;
            justify-content: space-between;
            background: linear-gradient(135deg, #1e1b4b 0%, #0f172a 100%);
            border: 1px solid rgba(56, 189, 248, 0.35);
            border-radius: 14px;
            padding: 14px 18px;
            margin-bottom: 14px;
          }
          .top-bar h2 { margin: 0; font-size: 18px; color: #38bdf8; }
          .btn-group { display: flex; gap: 8px; }
          button {
            background: linear-gradient(135deg, #0284c7, #0369a1);
            border: 1px solid #38bdf8;
            color: #fff;
            padding: 8px 14px;
            border-radius: 9px;
            font-family: 'Tajawal', sans-serif;
            font-weight: 800;
            cursor: pointer;
          }
          table {
            width: 100%;
            border-collapse: collapse;
            background: rgba(30, 41, 59, 0.75);
            border-radius: 12px;
            overflow: hidden;
          }
          th, td {
            padding: 10px 12px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.08);
            text-align: right;
            font-size: 13px;
          }
          th {
            background: rgba(2, 132, 199, 0.25);
            color: #fbbf24;
            font-weight: 800;
          }
          @media print {
            body { background: #fff; color: #000; }
            .btn-group { display: none; }
            th { background: #e2e8f0; color: #000; }
          }
        </style>
      </head>
      <body>
        <div class="top-bar">
          <div>
            <h2>📄 كشف وتقرير الوحدات — مكتبة محمد عادل</h2>
            <div style="font-size:12px;color:#cbd5e1;margin-top:3px;">إجمالي الوحدات المرصودة في المشهد: #{rows.length} وحدة</div>
          </div>
          <div class="btn-group">
            <button onclick="window.print()">🖨️ طباعة / حفظ PDF</button>
          </div>
        </div>
        <table>
          <thead>
            <tr>
              <th>#</th>
              <th>كود الوحدة</th>
              <th>اسم الوحدة</th>
              <th>العرض (سم)</th>
              <th>العمق (سم)</th>
              <th>الارتفاع (سم)</th>
              <th>قطع منقوشة بالثمرة</th>
            </tr>
          </thead>
          <tbody id="reportBody"></tbody>
        </table>
        <script>
          const ROWS = #{rows_json};
          const tbody = document.getElementById('reportBody');
          if (ROWS.length === 0) {
            tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;padding:24px;">لا توجد وحدات في المشهد حالياً.</td></tr>';
          } else {
            tbody.innerHTML = ROWS.map(r => `
              <tr>
                <td>${r.index}</td>
                <td style="font-weight:800;color:#38bdf8;">${r.code}</td>
                <td style="font-weight:700;">${r.name}</td>
                <td>${r.width_cm}</td>
                <td>${r.depth_cm}</td>
                <td>${r.height_cm}</td>
                <td>${r.grained_parts} قطعة</td>
              </tr>
            `).join('');
          }
        </script>
      </body>
      </html>
    HTML

    dlg.set_html(html)
    dlg.show
    @units_report_dlg = dlg
    true
  end

  # 11) لوحة التسعير وإصدار عرض السعر (Pricing Studio Dialog)
  @pricing_studio_dlg = nil

  def self.open_pricing_studio_dialog
    rows = collect_project_units_summary
    total_linear_m = (rows.inject(0.0) { |s, r| s + r['width_cm'].to_f } / 100.0).round(2) rescue 0.0
    total_area_m2  = (rows.inject(0.0) { |s, r| s + ((r['width_cm'].to_f * r['height_cm'].to_f) / 10000.0) }).round(2) rescue 0.0

    dlg = UI::HtmlDialog.new({
      :dialog_title    => 'لوحة التسعير وعرض السعر — مكتبة محمد عادل',
      :preferences_key => 'DolaPricingStudio_v2',
      :scrollable      => true,
      :resizable       => true,
      :width           => 540,
      :height          => 620,
      :style           => UI::HtmlDialog::STYLE_DIALOG
    })

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="ar" dir="rtl">
      <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@500;700;800&display=swap" rel="stylesheet">
        <style>
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 16px;
            font-family: 'Tajawal', sans-serif;
            background: linear-gradient(160deg, #1e1b4b 0%, #0f172a 100%);
            color: #f8fafc;
          }
          .card {
            background: rgba(30, 41, 59, 0.78);
            border: 1px solid rgba(56, 189, 248, 0.3);
            border-radius: 14px;
            padding: 14px;
            margin-bottom: 12px;
          }
          h2 { margin: 0 0 6px; font-size: 17px; color: #fbbf24; }
          .stats-grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 8px;
            margin-top: 8px;
          }
          .stat-box {
            background: rgba(15, 23, 42, 0.9);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 10px;
            padding: 8px;
            text-align: center;
          }
          .stat-val { font-size: 17px; font-weight: 800; color: #38bdf8; }
          .stat-lbl { font-size: 11px; color: #cbd5e1; }
          .form-row {
            display: grid;
            grid-template-columns: 1.2fr 1fr;
            align-items: center;
            gap: 8px;
            margin-bottom: 9px;
          }
          label { font-size: 13px; font-weight: 700; }
          input {
            width: 100%;
            padding: 8px 10px;
            border-radius: 8px;
            background: #0f172a;
            border: 1px solid rgba(56, 189, 248, 0.4);
            color: #fff;
            font-family: 'Tajawal', sans-serif;
            font-size: 13px;
            font-weight: 700;
          }
          .total-banner {
            background: linear-gradient(135deg, rgba(16, 185, 129, 0.25), rgba(2, 132, 199, 0.25));
            border: 1px solid #34d399;
            border-radius: 14px;
            padding: 14px;
            text-align: center;
          }
          .total-num { font-size: 26px; font-weight: 800; color: #34d399; margin: 4px 0; }
          .print-btn {
            width: 100%;
            margin-top: 10px;
            background: linear-gradient(135deg, #d97706, #b45309);
            border: none;
            color: #fff;
            padding: 11px;
            border-radius: 10px;
            font-family: 'Tajawal', sans-serif;
            font-size: 14px;
            font-weight: 800;
            cursor: pointer;
          }
        </style>
      </head>
      <body>
        <div class="card">
          <h2>💰 استوديو التسعير الذكي — مكتبة محمد عادل</h2>
          <div class="stats-grid">
            <div class="stat-box">
              <div class="stat-val">#{rows.length}</div>
              <div class="stat-lbl">عدد الوحدات</div>
            </div>
            <div class="stat-box">
              <div class="stat-val" id="linearM">#{total_linear_m}</div>
              <div class="stat-lbl">إجمالي المتر الطولي</div>
            </div>
            <div class="stat-box">
              <div class="stat-val" id="areaM2">#{total_area_m2}</div>
              <div class="stat-lbl">المساحة الواجهية (م²)</div>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="form-row">
            <label>اسم العميل / المشروع:</label>
            <input type="text" id="clientName" placeholder="اسم العميل...">
          </div>
          <div class="form-row">
            <label>سعر المتر المربع (ج.م):</label>
            <input type="number" id="pricePerM2" value="6500" oninput="calcTotal()">
          </div>
          <div class="form-row">
            <label>تكلفة الإكسسوارات والمفصلات (ج.م):</label>
            <input type="number" id="accessoriesCost" value="3500" oninput="calcTotal()">
          </div>
          <div class="form-row">
            <label>تكلفة النقل والتركيب (ج.م):</label>
            <input type="number" id="installCost" value="1500" oninput="calcTotal()">
          </div>
          <div class="form-row">
            <label>خصم خاص للعميل (ج.م):</label>
            <input type="number" id="discountVal" value="0" oninput="calcTotal()">
          </div>
        </div>

        <div class="total-banner">
          <div style="font-size:13px;color:#cbd5e1;">إجمالي عرض السعر النهائي</div>
          <div class="total-num" id="finalTotal">0 ج.م</div>
          <button class="print-btn" onclick="window.print()">🖨️ طباعة عرض السعر للعميل</button>
        </div>

        <script>
          const AREA_M2 = #{total_area_m2};
          function calcTotal() {
            const pm2  = parseFloat(document.getElementById('pricePerM2').value || '0') || 0;
            const acc  = parseFloat(document.getElementById('accessoriesCost').value || '0') || 0;
            const inst = parseFloat(document.getElementById('installCost').value || '0') || 0;
            const disc = parseFloat(document.getElementById('discountVal').value || '0') || 0;
            const total = Math.max(0, Math.round((AREA_M2 * pm2) + acc + inst - disc));
            document.getElementById('finalTotal').textContent = total.toLocaleString('ar-EG') + ' ج.م';
          }
          calcTotal();
        </script>
      </body>
      </html>
    HTML

    dlg.set_html(html)
    dlg.show
    @pricing_studio_dlg = dlg
    true
  end

  # ============================================================================
  #  أداة رسم الحوائط (Dola Wall Drawer)
  #  • تدخل سمك الحيطة وارتفاعها أولاً ثم ترسم حيطة حيطة بكتابة الطول.
  #  • الزاوية: 90° يمين/شمال، زاوية مخصوصة، أو بالمثلث (ضلع + ضلع + وتر).
  #  • إغلاق تلقائي لو ضغطت قرب نقطة بداية أول حائط.
  #  • "إنهاء هنا (فتحة باب)" يقفل السلسلة مفتوحة ويترك الباقي فراغ.
  #  • كل حائط يُنشأ كجروب مستقل بنفس خصائص MHD Room Builder (النوع/P1/P2)
  #    فيشتغل سناب وحدات المكتبة على الحوائط الجديدة مباشرة.
  # ============================================================================
  module DolaWallDrawer
    extend self

    ROOM_DICT  = 'MHD_ROOM_BUILDER'.freeze
    WALL_DICT  = 'DolaWalls'.freeze
    CLOSE_PX   = 16
    CM_PER_IN  = 2.54
    AXES = {
      'x+' => [1.0, 0.0], 'x-' => [-1.0, 0.0],
      'y+' => [0.0, 1.0], 'y-' => [0.0, -1.0]
    }.freeze

    def settings
      @settings ||= { 'thickness' => 12.0, 'height' => 280.0, 'align' => 'inner', 'flip' => false }
    end

    # ------------------------------------------------------------------------
    #  حسابات هندسية خالصة (نقاط [x, y] بالبوصة) — بدون أي استدعاء لسكتش أب
    # ------------------------------------------------------------------------

    # الزاوية الداخلية (بالدرجات) عند الركن من مثلث:
    # a = مسافة على الضلع السابق، b = مسافة على الضلع الجديد، h = الوتر بينهما
    def triangle_interior_angle(a, b, h)
      a = a.to_f
      b = b.to_f
      h = h.to_f
      return nil if a <= 0.0 || b <= 0.0 || h <= 0.0
      return nil if h >= a + b || h <= (a - b).abs
      cos_t = (a * a + b * b - h * h) / (2.0 * a * b)
      cos_t = [[cos_t, -1.0].max, 1.0].min
      Math.acos(cos_t) * 180.0 / Math::PI
    end

    def signed_area(pts)
      sum = 0.0
      pts.each_with_index do |p, i|
        q = pts[(i + 1) % pts.length]
        sum += p[0] * q[1] - q[0] * p[1]
      end
      sum * 0.5
    end

    # هل داخل الغرفة على يسار اتجاه الرسم؟
    def interior_on_left?(pts2, closed)
      if closed && pts2.length >= 3
        return signed_area(pts2) > 0.0
      end
      turn = 0.0
      (1...(pts2.length - 1)).each do |i|
        a = pts2[i - 1]
        b = pts2[i]
        c = pts2[i + 1]
        d0x = b[0] - a[0]
        d0y = b[1] - a[1]
        d1x = c[0] - b[0]
        d1y = c[1] - b[1]
        l0 = Math.sqrt(d0x * d0x + d0y * d0y)
        l1 = Math.sqrt(d1x * d1x + d1y * d1y)
        next if l0 < 1e-9 || l1 < 1e-9
        turn += (d0x * d1y - d0y * d1x) / (l0 * l1)
      end
      return turn > 0.0 if turn.abs > 1e-6
      true
    end

    # إزاحة سلسلة نقاط جهة اليسار بمسافة dist (السالب = يمين) مع ركن Miter
    def offset_chain(pts, dist, closed)
      n = pts.length
      return pts.map { |p| [p[0], p[1]] } if n < 2 || dist.abs < 1e-9

      dirs = []
      seg_count = closed ? n : n - 1
      seg_count.times do |i|
        a = pts[i]
        b = pts[(i + 1) % n]
        dx = b[0] - a[0]
        dy = b[1] - a[1]
        len = Math.sqrt(dx * dx + dy * dy)
        len = 1.0 if len < 1e-12
        dirs << [dx / len, dy / len]
      end

      out = []
      n.times do |i|
        d0 = nil
        d1 = nil
        if closed
          d0 = dirs[(i - 1) % n]
          d1 = dirs[i]
        else
          d0 = dirs[i - 1] if i > 0
          d1 = dirs[i] if i < n - 1
        end
        n0 = d0 ? [-d0[1], d0[0]] : nil
        n1 = d1 ? [-d1[1], d1[0]] : nil
        if n0.nil?
          out << [pts[i][0] + n1[0] * dist, pts[i][1] + n1[1] * dist]
        elsif n1.nil?
          out << [pts[i][0] + n0[0] * dist, pts[i][1] + n0[1] * dist]
        else
          k = 1.0 + n0[0] * n1[0] + n0[1] * n1[1]
          k = 0.25 if k < 0.25
          mx = (n0[0] + n1[0]) / k
          my = (n0[1] + n1[1]) / k
          out << [pts[i][0] + mx * dist, pts[i][1] + my * dist]
        end
      end
      out
    end

    # يحسب مستطيلات الحوائط (بقصّات Miter عند الأركان) + نقطتي الوجه الداخلي P1/P2
    # align: 'inner' الخط = الوجه الداخلي | 'center' منتصف | 'outer' الوجه الخارجي
    def wall_layout(pts2, closed, thickness, align, flip)
      n = pts2.length
      return nil if n < 2
      return nil if closed && n < 3
      return nil if thickness.to_f <= 0.0

      left = interior_on_left?(pts2, closed)
      left = !left if flip
      work = left ? pts2 : pts2.reverse

      t = thickness.to_f
      d_in = 0.0
      d_out = t
      if align == 'center'
        d_in = t * 0.5
        d_out = t * 0.5
      elsif align == 'outer'
        d_in = t
        d_out = 0.0
      end

      inner = offset_chain(work, d_in, closed)
      outer = offset_chain(work, -d_out, closed)

      count = closed ? n : n - 1
      walls = []
      count.times do |i|
        j = (i + 1) % n
        walls << {
          :p1   => inner[i],
          :p2   => inner[j],
          :quad => [inner[i], inner[j], outer[j], outer[i]]
        }
      end
      walls
    end

    def parse_length(text)
      s = text.to_s.strip.tr('٠١٢٣٤٥٦٧٨٩٫،', '0123456789..')
      return nil if s.empty?
      if s =~ /\A\d+(\.\d+)?\z/
        return s.to_f.cm
      end
      begin
        s.to_l
      rescue
        nil
      end
    end

    def fmt_cm(inches)
      format('%.1f', inches.to_f * CM_PER_IN)
    end

    # ------------------------------------------------------------------------
    #  بناء الحوائط داخل الموديل (عملية واحدة = Undo واحد)
    # ------------------------------------------------------------------------
    def wall_material(model)
      mat = model.materials['حوائط Dola']
      unless mat
        mat = model.materials.add('حوائط Dola')
        mat.color = Sketchup::Color.new(236, 234, 228)
      end
      mat
    end

    def clean_points(world_pts, closed)
      out = []
      world_pts.each do |p|
        next if !out.empty? && out.last.distance(p) < 0.02
        out << p
      end
      out.pop if closed && out.length > 1 && out.first.distance(out.last) < 0.02
      out
    end

    def build_walls!(world_pts, closed)
      model = Sketchup.active_model
      st = settings
      thickness = st['thickness'].to_f.cm
      height = st['height'].to_f.cm

      pts = clean_points(world_pts, closed)
      if pts.length < 2 || (closed && pts.length < 3)
        return [false, 'النقاط غير كافية لإنشاء حوائط']
      end

      inv = model.edit_transform.inverse
      local = pts.map { |p| p.transform(inv) }
      z = local.first.z.to_f
      pts2 = local.map { |p| [p.x.to_f, p.y.to_f] }

      walls = wall_layout(pts2, closed, thickness, st['align'], st['flip'])
      return [false, 'تعذر حساب الحوائط (راجع السمك والأطوال)'] unless walls && !walls.empty?

      model.start_operation('رسم الحوائط', true)
      begin
        room = model.active_entities.add_group
        room.name = closed ? 'غرفة (حوائط)' : 'حوائط'
        mat = wall_material(model)

        walls.each_with_index do |w, idx|
          g = room.entities.add_group
          pts3 = w[:quad].map { |q| Geom::Point3d.new(q[0], q[1], z) }
          face = g.entities.add_face(pts3)
          face.pushpull(face.normal.z >= 0 ? height : -height)
          g.entities.grep(Sketchup::Face).each do |f|
            f.material = mat
            f.back_material = mat
          end
          g.name = "حائط #{idx + 1}"
          g.set_attribute(ROOM_DICT, 'النوع', 'حائط')
          g.set_attribute(ROOM_DICT, 'P1', format('%.6f|%.6f|%.6f', w[:p1][0], w[:p1][1], z))
          g.set_attribute(ROOM_DICT, 'P2', format('%.6f|%.6f|%.6f', w[:p2][0], w[:p2][1], z))
          g.set_attribute(WALL_DICT, 'thickness_cm', st['thickness'].to_f)
          g.set_attribute(WALL_DICT, 'height_cm', st['height'].to_f)
        end

        room.set_attribute(WALL_DICT, 'closed', closed)
        model.commit_operation
        [true, closed ? "تم إنشاء غرفة من #{walls.length} حوائط" : "تم إنشاء #{walls.length} حائط (سلسلة مفتوحة)"]
      rescue => e
        model.abort_operation
        [false, "تعذر إنشاء الحوائط: #{e.message}"]
      end
    end

    # ------------------------------------------------------------------------
    #  الأداة التفاعلية (Tool)
    # ------------------------------------------------------------------------
    class WallTool
      def initialize
        @pts = []
        @z = 0.0
        @cursor = nil
        @prev_dir = nil
        @dir_mode = :mouse
        @axis_key = 'x+'
        @turn_side = :right
        @interior = 90.0
        @typed_in = nil
        @near_first = false
        @view = nil
        @mouse = nil
        @last_push = Time.at(0)
        @msg = nil
      end

      attr_reader :pts

      # ---------- أحداث سكتش أب ----------
      def activate
        @view = Sketchup.active_model.active_view
        reset_chain
        DolaWallDrawer.on_tool_activated(self)
        Sketchup.vcb_label = 'الطول (سم)'
        Sketchup.vcb_value = ''
        update_status
        @view.invalidate
      end

      def deactivate(view)
        DolaWallDrawer.on_tool_deactivated
        view.invalidate
      end

      def resume(view)
        @view = view
        update_status
        view.invalidate
      end

      def suspend(view)
      end

      def onCancel(reason, view)
        if @pts.empty?
          Sketchup.active_model.select_tool(nil) if reason.to_i == 0
        else
          reset_chain
          push_state('تم إلغاء الرسم الحالي')
          update_status
          view.invalidate
        end
      end

      def enableVCB?
        true
      end

      def onSetCursor
        UI.set_cursor(632)
      rescue
        nil
      end

      def onMouseMove(flags, x, y, view)
        @view = view
        @mouse = [x, y]
        pt = ground_point(view, x, y)
        @cursor = pt if pt
        @near_first = false
        if @pts.length >= 3 && @typed_in.nil?
          sc = view.screen_coords(@pts.first)
          @near_first = Math.hypot(sc.x - x, sc.y - y) <= CLOSE_PX
        end
        view.invalidate
        push_state_throttled
      end

      def onLButtonDown(flags, x, y, view)
        onMouseMove(flags, x, y, view)
        if @pts.empty?
          start_at(@cursor) if @cursor
          return
        end
        if @near_first
          close_room
          return
        end
        len = pending_len_in
        if len
          add_segment(len)
        else
          push_state('حرّك الماوس ناحية الاتجاه المطلوب أو اكتب الطول')
        end
      end

      def onUserText(text, view)
        len = DolaWallDrawer.parse_length(text)
        if len.nil? || len <= 0.0
          UI.beep
          return
        end
        add_segment(len)
      end

      def getExtents
        bb = Geom::BoundingBox.new
        @pts.each { |p| bb.add(p) }
        bb.add(@cursor) if @cursor
        pe = pending_endpoint
        bb.add(pe) if pe
        bb.add(Geom::Point3d.new(0, 0, 0)) if bb.empty?
        bb
      end

      def draw(view)
        return if @view.nil?
        draw_preview(view)
      rescue => e
        puts "DolaWallDrawer draw error: #{e.message}"
      end

      # ---------- أوامر من لوحة التحكم ----------
      def set_dir(h)
        mode = h['mode'].to_s
        if mode == 'axis'
          key = h['axis'].to_s
          @axis_key = AXES.key?(key) ? key : 'x+'
          @dir_mode = :axis
        elsif mode == 'turn'
          @dir_mode = :turn
          @turn_side = (h['side'].to_s == 'left') ? :left : :right
          ang = h['interior'].to_f
          if h['tri'].is_a?(Hash)
            tri = DolaWallDrawer.triangle_interior_angle(h['tri']['a'], h['tri']['b'], h['tri']['h'])
            if tri.nil?
              push_state('المثلث غير صالح: الوتر لازم يكون أكبر من فرق الضلعين وأقل من مجموعهما')
            else
              ang = tri
            end
          end
          ang = 90.0 if ang <= 0.0
          @interior = [[ang, 5.0].max, 175.0].min
        else
          @dir_mode = :mouse
        end
        @view.invalidate if @view
        push_state
      end

      def set_typed_cm(cm)
        v = cm.to_f
        @typed_in = v > 0.0 ? v.cm : nil
        @near_first = false if @typed_in
        @view.invalidate if @view
        push_state_throttled
      end

      def start_at(pt)
        @pts = [pt.clone]
        @z = pt.z.to_f
        @prev_dir = nil
        @typed_in = nil
        push_state('تم تحديد نقطة البداية — حدّد الاتجاه واكتب الطول')
        update_status
        @view.invalidate if @view
      end

      def start_at_origin
        start_at(Geom::Point3d.new(0, 0, 0))
      end

      def add_segment(len_in)
        if @pts.empty?
          push_state('اضغط على نقطة البداية أولاً (أو زر: ابدأ من نقطة الأصل)')
          return false
        end
        if len_in.to_f <= 0.01
          push_state('اكتب طولاً أكبر من صفر')
          return false
        end
        dir = current_direction
        unless dir
          push_state('حرّك الماوس لتحديد اتجاه الضلع أولاً')
          return false
        end
        new_pt = @pts.last.offset(dir, len_in)
        @pts << new_pt
        @prev_dir = dir.clone
        @typed_in = nil
        if @pts.length >= 4 && new_pt.distance(@pts.first) < 0.5.cm
          @pts.pop
          close_room
          return true
        end
        push_state("تمت إضافة ضلع #{DolaWallDrawer.fmt_cm(len_in)} سم", true)
        update_status
        @view.invalidate if @view
        true
      end

      def undo_segment
        if @pts.length > 1
          @pts.pop
        elsif @pts.length == 1
          @pts = []
        end
        @prev_dir = nil
        if @pts.length >= 2
          v = @pts.last - @pts[-2]
          if v.length > 0.0001
            v.normalize!
            @prev_dir = v
          end
        end
        @typed_in = nil
        push_state('تم التراجع عن آخر ضلع', true)
        update_status
        @view.invalidate if @view
      end

      def finish_open
        if @pts.length < 2
          push_state('ارسم ضلعاً واحداً على الأقل أولاً')
          return
        end
        build_and_reset(false)
      end

      def close_room
        if @pts.length < 3
          push_state('محتاج ٣ نقاط على الأقل (ضلعين) لإغلاق الغرفة')
          return
        end
        build_and_reset(true)
      end

      def reset_chain
        @pts = []
        @prev_dir = nil
        @typed_in = nil
        @near_first = false
      end

      def push_state_public(msg = nil)
        push_state(msg)
      end

      def state_hash(msg = nil, reset_field = false)
        total = 0.0
        (1...@pts.length).each { |i| total += @pts[i].distance(@pts[i - 1]) }
        pend = pending_len_in
        {
          'started'   => !@pts.empty?,
          'segs'      => [@pts.length - 1, 0].max,
          'total_cm'  => (total * CM_PER_IN).round(1),
          'pend_cm'   => pend ? (pend * CM_PER_IN).round(1) : nil,
          'can_close' => @pts.length >= 3,
          'can_finish' => @pts.length >= 2,
          'interior'  => @interior.round(1),
          'mode'      => @dir_mode.to_s,
          'near'      => @near_first,
          'msg'       => msg,
          'clear'     => reset_field
        }
      end

      private

      def build_and_reset(closed)
        ok, message = DolaWallDrawer.build_walls!(@pts, closed)
        if ok
          reset_chain
          push_state(message + ' — ابدأ حيطة جديدة بالضغط على نقطة', true)
          update_status
        else
          push_state(message)
        end
        @view.invalidate if @view
      end

      def ground_point(view, x, y)
        if @pts.empty?
          ip = Sketchup::InputPoint.new
          ip.pick(view, x, y)
          return ip.valid? ? ip.position : nil
        end
        ray = view.pickray(x, y)
        Geom.intersect_line_plane(ray, [Geom::Point3d.new(0, 0, @z), Z_AXIS])
      end

      def mouse_direction(last)
        return nil unless @cursor
        v = Geom::Vector3d.new(@cursor.x - last.x, @cursor.y - last.y, 0)
        return nil if v.length < 0.01
        ang = Math.atan2(v.y, v.x)
        base = @prev_dir ? Math.atan2(@prev_dir.y, @prev_dir.x) : 0.0
        rel = ang - base
        step = Math::PI / 2.0
        snapped = (rel / step).round * step
        if (rel - snapped).abs < (5.0 * Math::PI / 180.0)
          ang = base + snapped
        end
        Geom::Vector3d.new(Math.cos(ang), Math.sin(ang), 0)
      end

      def current_direction
        return nil if @pts.empty?
        last = @pts.last
        if @dir_mode == :axis
          a = AXES[@axis_key] || AXES['x+']
          return Geom::Vector3d.new(a[0], a[1], 0)
        end
        if @dir_mode == :turn && @prev_dir
          turn = (180.0 - @interior) * Math::PI / 180.0
          turn = -turn unless @turn_side == :left
          tr = Geom::Transformation.rotation(last, Z_AXIS, turn)
          v = @prev_dir.transform(tr)
          v.normalize!
          return v
        end
        mouse_direction(last)
      end

      def pending_len_in
        return @typed_in if @typed_in && @typed_in > 0.0
        return nil if @pts.empty? || @cursor.nil?
        dir = current_direction
        return nil unless dir
        last = @pts.last
        v = Geom::Vector3d.new(@cursor.x - last.x, @cursor.y - last.y, 0)
        proj = v.dot(dir)
        return nil if proj <= 0.0
        cm = (proj * CM_PER_IN).round
        cm = 1 if cm < 1
        cm / CM_PER_IN
      end

      def pending_endpoint
        return nil if @pts.empty?
        return @pts.first if @near_first && @pts.length >= 3
        dir = current_direction
        len = pending_len_in
        return nil unless dir && len
        @pts.last.offset(dir, len)
      end

      def update_status
        if @pts.empty?
          Sketchup.status_text = 'رسم الحوائط: اضغط لتحديد نقطة البداية (أو استخدم زر نقطة الأصل في اللوحة)'
        else
          Sketchup.status_text = 'اكتب الطول في اللوحة أو في خانة القياسات واضغط Enter — اضغط قرب البداية لإغلاق الغرفة — Esc لإلغاء الرسم الجاري'
        end
      end

      def push_state(msg = nil, reset_field = false)
        DolaWallDrawer.push_state(state_hash(msg, reset_field))
      end

      def push_state_throttled
        now = Time.now
        return if now - @last_push < 0.08
        @last_push = now
        push_state
      end

      def circle_2d(cx, cy, r, steps = 28)
        pts = []
        steps.times do |i|
          a = 2.0 * Math::PI * i / steps
          pts << Geom::Point3d.new(cx + r * Math.cos(a), cy + r * Math.sin(a), 0)
        end
        pts
      end

      def draw_preview(view)
        st = DolaWallDrawer.settings
        z = @z
        pend = pending_endpoint
        closing = @near_first && @pts.length >= 3

        if @pts.empty?
          view.draw_points([@cursor], 10, 3, 'blue') if @cursor
          return
        end

        chain = @pts.dup
        chain << pend if pend && !closing
        if chain.length >= 2
          pts2 = chain.map { |p| [p.x.to_f, p.y.to_f] }
          layout = DolaWallDrawer.wall_layout(pts2, closing, st['thickness'].to_f.cm, st['align'], st['flip'])
          if layout
            layout.each do |w|
              q3 = w[:quad].map { |q| Geom::Point3d.new(q[0], q[1], z) }
              view.drawing_color = Sketchup::Color.new(80, 150, 255, 70)
              view.draw(GL_QUADS, q3)
              view.line_width = 2
              view.drawing_color = Sketchup::Color.new(20, 90, 220, 255)
              view.draw(GL_LINE_LOOP, q3)
            end
          end
        end

        if @pts.length >= 2
          view.line_width = 3
          view.drawing_color = Sketchup::Color.new(255, 140, 0, 255)
          view.draw(GL_LINE_STRIP, @pts)
        end

        if pend && !closing
          view.line_width = 2
          view.line_stipple = '-'
          view.drawing_color = Sketchup::Color.new(30, 170, 80, 255)
          view.draw(GL_LINES, [@pts.last, pend])
          view.line_stipple = ''
        end

        view.draw_points([@pts.first], 11, 2, closing ? 'lime' : 'green')

        # دائرة الإغلاق التلقائي عند نقطة البداية
        if @pts.length >= 3
          sc = view.screen_coords(@pts.first)
          radius = closing ? CLOSE_PX * 1.35 : 9.0
          view.line_width = closing ? 3 : 1
          view.drawing_color = closing ? Sketchup::Color.new(0, 200, 90, 255) : Sketchup::Color.new(120, 120, 120, 255)
          view.draw2d(GL_LINE_LOOP, circle_2d(sc.x, sc.y, radius))
        end

        # أبعاد الضلع الجاري
        if pend && view.respond_to?(:draw_text)
          len = pend.distance(@pts.last)
          mid = Geom.linear_combination(0.5, @pts.last, 0.5, pend)
          sp = view.screen_coords(mid)
          label = "#{DolaWallDrawer.fmt_cm(len)} سم"
          label += "  ∠#{@interior.round(1)}°" if @dir_mode == :turn && @prev_dir
          view.draw_text(Geom::Point3d.new(sp.x + 10, sp.y - 20, 0), label, { :size => 12, :bold => true })
        end
      end
    end

    # ------------------------------------------------------------------------
    #  لوحة التحكم (HtmlDialog) + ربطها بالأداة
    # ------------------------------------------------------------------------
    def activate_tool
      model = Sketchup.active_model
      model.select_tool(WallTool.new)
      true
    rescue => e
      UI.messagebox("تعذر تشغيل أداة رسم الحوائط:\n#{e.message}")
      false
    end

    def on_tool_activated(tool)
      @tool = tool
      open_panel
    end

    def on_tool_deactivated
      @tool = nil
      close_panel
    end

    def push_state(hash)
      return unless @dlg && @panel_ready
      @dlg.execute_script("DolaWalls.setState(#{hash.to_json});")
    rescue
      nil
    end

    def close_panel
      return unless @dlg
      @closing_panel = true
      begin
        @dlg.close
      rescue
        nil
      end
      @dlg = nil
      @panel_ready = false
      @closing_panel = false
    end

    def open_panel
      if @dlg && @dlg.visible?
        @dlg.bring_to_front rescue nil
        return
      end
      @panel_ready = false
      @dlg = UI::HtmlDialog.new({
        :dialog_title    => 'رسم الحوائط — مكتبة محمد عادل',
        :preferences_key => 'DolaWallDrawer_v1',
        :scrollable      => false,
        :resizable       => true,
        :width           => 380,
        :height          => 800,
        :left            => 70,
        :top             => 70,
        :style           => UI::HtmlDialog::STYLE_UTILITY
      })
      @dlg.set_html(panel_html)

      @dlg.add_action_callback('wall_ready') do |_ctx|
        @panel_ready = true
        @dlg.execute_script("DolaWalls.setSettings(#{settings.to_json});")
        @tool.push_state_public if @tool
      end

      @dlg.add_action_callback('wall_settings') do |_ctx, json|
        begin
          h = JSON.parse(json.to_s)
          th = h['thickness'].to_f
          ht = h['height'].to_f
          settings['thickness'] = th if th > 0.0
          settings['height'] = ht if ht > 0.0
          al = h['align'].to_s
          settings['align'] = %w[inner center outer].include?(al) ? al : 'inner'
          settings['flip'] = (h['flip'] == true)
          Sketchup.active_model.active_view.invalidate
        rescue
          nil
        end
      end

      @dlg.add_action_callback('wall_dir') do |_ctx, json|
        begin
          @tool.set_dir(JSON.parse(json.to_s)) if @tool
        rescue
          nil
        end
      end

      @dlg.add_action_callback('wall_pending') do |_ctx, json|
        begin
          h = JSON.parse(json.to_s)
          @tool.set_typed_cm(h['len']) if @tool
        rescue
          nil
        end
      end

      @dlg.add_action_callback('wall_add') do |_ctx, json|
        begin
          h = JSON.parse(json.to_s)
          cm = h['len'].to_f
          if @tool
            if cm > 0.0
              @tool.add_segment(cm.cm)
            else
              @tool.push_state_public('اكتب طول الضلع بالسنتيمتر أولاً')
            end
          end
        rescue
          nil
        end
      end

      @dlg.add_action_callback('wall_origin') { |_ctx| @tool.start_at_origin if @tool }
      @dlg.add_action_callback('wall_undo')   { |_ctx| @tool.undo_segment if @tool }
      @dlg.add_action_callback('wall_finish') { |_ctx| @tool.finish_open if @tool }
      @dlg.add_action_callback('wall_close')  { |_ctx| @tool.close_room if @tool }
      @dlg.add_action_callback('wall_exit')   { |_ctx| Sketchup.active_model.select_tool(nil) }

      @dlg.set_on_closed do
        unless @closing_panel
          @dlg = nil
          @panel_ready = false
          Sketchup.active_model.select_tool(nil) if @tool
        end
      end

      @dlg.show
    end

    def panel_html
      <<~'HTML'
        <!DOCTYPE html>
        <html lang="ar" dir="rtl">
        <head>
        <meta charset="UTF-8">
        <link href="https://fonts.googleapis.com/css2?family=Tajawal:wght@400;500;700;800&display=swap" rel="stylesheet">
        <style>
          *{box-sizing:border-box;user-select:none}
          :root{--bg:#07131d;--card:#0c1d2a;--line:#2c5068;--green:#4de37a;--blue:#8ad8ff;--gold:#ffd54f;--ease:cubic-bezier(.22,.8,.3,1)}
          html,body{margin:0;height:100%;font-family:'Tajawal','Segoe UI',Tahoma,sans-serif;color:#eaf4f8;
            background:radial-gradient(700px 400px at 90% -10%,rgba(192,38,211,.22),transparent 60%),radial-gradient(600px 400px at 0 110%,rgba(77,227,122,.12),transparent 55%),var(--bg);overflow-x:hidden}
          .wrap{padding:12px;display:flex;flex-direction:column;gap:10px}
          .head{display:flex;align-items:center;gap:10px;padding:10px 12px;border-radius:14px;border:1px solid var(--line);
            background:linear-gradient(135deg,rgba(192,38,211,.28),rgba(14,42,58,.9));box-shadow:0 8px 24px rgba(0,0,0,.35)}
          .head .ico{width:34px;height:34px;border-radius:10px;background:linear-gradient(135deg,#d946ef,#86198f);display:flex;align-items:center;justify-content:center;font-size:18px}
          .head b{font-size:16px;font-weight:800}.head small{display:block;color:#b8cbd8;font-size:11px;margin-top:2px}
          .card{border:1px solid var(--line);border-radius:14px;background:linear-gradient(180deg,rgba(14,32,45,.92),rgba(9,22,32,.95));padding:10px;animation:rise .45s var(--ease) both}
          .card h3{margin:0 0 8px;font-size:13px;font-weight:800;color:var(--blue);display:flex;align-items:center;gap:6px}
          .card h3:before{content:"";width:7px;height:7px;border-radius:50%;background:var(--green);box-shadow:0 0 8px var(--green)}
          .row{display:grid;grid-template-columns:1fr 1fr;gap:8px}
          label{display:block;font-size:11px;font-weight:700;color:#c6dae6;margin-bottom:4px}
          input[type=number],select{width:100%;height:36px;background:#07151e;color:#fff;border:1px solid var(--line);border-radius:10px;padding:0 9px;font-family:inherit;font-size:14px;outline:none;transition:.18s}
          input[type=number]:focus,select:focus{border-color:var(--green);box-shadow:0 0 0 3px rgba(77,227,122,.18)}
          .chk{display:flex;align-items:center;gap:7px;margin-top:8px;font-size:12px;color:#c6dae6;cursor:pointer}
          .chips{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:8px}
          .chip{flex:1 1 auto;min-width:54px;height:34px;border:1px solid var(--line);border-radius:10px;background:linear-gradient(180deg,#12293a,#0e2130);color:#d6e6ef;font-family:inherit;font-size:12px;font-weight:700;cursor:pointer;transition:.18s var(--ease)}
          .chip:hover{transform:translateY(-2px);border-color:var(--blue)}
          .chip.on{background:linear-gradient(180deg,#1a4a3a,#123a2d);border-color:var(--green);color:var(--green);box-shadow:0 0 14px rgba(77,227,122,.25)}
          .sub{font-size:10.5px;color:#8fb2c4;margin:2px 0 6px}
          .tri{display:none;margin-top:6px}.tri.show{display:block;animation:rise .3s var(--ease) both}
          .tri .row3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:6px}
          .angle{margin-top:7px;padding:7px;border-radius:10px;background:#0d2a22;border:1px solid rgba(77,227,122,.4);text-align:center;font-weight:800;color:var(--green);font-size:13px}
          .angle.bad{background:#32191b;border-color:#7f3030;color:#ffb0a8}
          .len{display:flex;gap:8px}
          .len input{flex:1;height:44px;font-size:20px;font-weight:800;text-align:center}
          .btn{height:42px;border:0;border-radius:12px;font-family:inherit;font-weight:800;font-size:13px;cursor:pointer;color:#fff;transition:.18s var(--ease)}
          .btn:hover{transform:translateY(-2px);filter:brightness(1.1)}.btn:active{transform:none}.btn[disabled]{opacity:.38;pointer-events:none}
          .add{background:linear-gradient(135deg,#5dff8d,#2fc863);color:#05200f;padding:0 16px;box-shadow:0 8px 20px rgba(77,227,122,.3)}
          .grid2{display:grid;grid-template-columns:1fr 1fr;gap:8px}
          .b-undo{background:linear-gradient(135deg,#3b5368,#2a3d4e)}.b-fin{background:linear-gradient(135deg,#f59e0b,#b45309)}
          .b-close{background:linear-gradient(135deg,#d946ef,#86198f)}.b-exit{background:linear-gradient(135deg,#7f3030,#561f1f)}
          .b-org{background:linear-gradient(135deg,#0ea5e9,#0369a1);width:100%;margin-top:2px}
          .stat{display:flex;justify-content:space-between;font-size:12px;color:#c6dae6;margin-bottom:6px}.stat b{color:var(--gold)}
          .msg{min-height:38px;padding:8px 10px;border-radius:10px;background:#0b1b27;border:1px dashed var(--line);font-size:12px;line-height:1.7;color:#cfe3ee}
          .tip{font-size:10.5px;color:#8fb2c4;line-height:1.7;margin-top:6px}
          @keyframes rise{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
          @media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
        </style>
        </head>
        <body oncontextmenu="return false;">
        <div class="wrap">
          <div class="head"><div class="ico">🧱</div><div><b>رسم الحوائط</b><small>اكتب القياسات والأداة ترسم وتولّد الزوايا</small></div></div>

          <div class="card">
            <h3>مواصفات الحيطة</h3>
            <div class="row">
              <div><label>السمك (سم)</label><input type="number" id="th" value="12" min="1" step="0.5"></div>
              <div><label>الارتفاع (سم)</label><input type="number" id="ht" value="280" min="10" step="1"></div>
            </div>
            <div style="margin-top:8px"><label>الخط المرسوم يمثّل</label>
              <select id="al"><option value="inner">الوجه الداخلي للغرفة (السمك للخارج)</option><option value="center">منتصف الحيطة</option><option value="outer">الوجه الخارجي (السمك للداخل)</option></select></div>
            <label class="chk"><input type="checkbox" id="fl"> اقلب جهة السمك</label>
          </div>

          <div class="card">
            <h3>اتجاه الضلع الجاي</h3>
            <div class="sub">الضلع الأول: بالماوس أو اختر اتجاه ثابت. بعد كده اختر يمين/شمال والزاوية.</div>
            <div class="chips" id="axes">
              <button class="chip" data-axis="y+">⬆ شمال</button><button class="chip" data-axis="x+">➡ شرق</button>
              <button class="chip" data-axis="y-">⬇ جنوب</button><button class="chip" data-axis="x-">⬅ غرب</button>
              <button class="chip on" id="mouseChip">🖱 بالماوس</button>
            </div>
            <div class="chips" id="sides">
              <button class="chip" data-side="left">↰ لف شمال</button><button class="chip" data-side="right">↱ لف يمين</button>
            </div>
            <div class="chips" id="angles">
              <button class="chip" data-ang="90">90°</button><button class="chip" data-ang="45">45°</button><button class="chip" data-ang="135">135°</button>
              <button class="chip" data-ang="custom">مخصوصة</button><button class="chip" data-ang="tri">📐 مثلث</button>
            </div>
            <div id="customBox" style="display:none"><label>الزاوية الداخلية بين الضلعين (درجة)</label><input type="number" id="cust" value="90" min="5" max="175" step="0.5"></div>
            <div class="tri" id="triBox">
              <div class="sub">خُد مسافة على الضلع السابق ومسافة على الضلع الجديد وقِس الوتر بينهم:</div>
              <div class="row3">
                <div><label>ضلع سابق</label><input type="number" id="ta" value="60" min="1" step="0.5"></div>
                <div><label>ضلع جديد</label><input type="number" id="tb" value="60" min="1" step="0.5"></div>
                <div><label>الوتر</label><input type="number" id="th2" value="85" min="1" step="0.5"></div>
              </div>
              <div class="angle" id="triOut">—</div>
            </div>
          </div>

          <div class="card">
            <h3>طول الضلع (سم)</h3>
            <div class="len"><input type="number" id="len" min="1" step="1" placeholder="مثال: 350"><button class="btn add" id="addBtn">➕ أضف</button></div>
            <div class="tip">اكتب الطول واضغط Enter. المعاينة بتظهر في الشاشة قبل التنفيذ.</div>
            <button class="btn b-org" id="orgBtn">📍 ابدأ من نقطة الأصل (0,0)</button>
          </div>

          <div class="card">
            <div class="stat"><span>الأضلاع: <b id="sSegs">0</b></span><span>الإجمالي: <b id="sTotal">0</b> سم</span><span>المعاينة: <b id="sPend">—</b></span></div>
            <div class="grid2">
              <button class="btn b-undo" id="undoBtn">↩ تراجع</button>
              <button class="btn b-fin" id="finBtn">🚪 إنهاء هنا (باب)</button>
              <button class="btn b-close" id="closeBtn">⭕ إغلاق الغرفة</button>
              <button class="btn b-exit" id="exitBtn">✖ خروج</button>
            </div>
            <div class="tip">الضغط بالماوس قرب نقطة البداية (الدايرة الخضراء) يقفل الغرفة تلقائي. «إنهاء هنا» يقفل الحيطة مفتوحة ويترك الباقي فراغ للباب.</div>
          </div>

          <div class="msg" id="msg">اضغط في الشاشة لتحديد نقطة البداية.</div>
        </div>
        <script>
        var S={mode:'mouse',axis:'x+',side:'right',ang:'90'};
        function $(i){return document.getElementById(i)}
        function post(n,o){ if(window.sketchup&&window.sketchup[n]) window.sketchup[n](o===undefined?'':JSON.stringify(o)); }
        function sendSettings(){ post('wall_settings',{thickness:parseFloat($('th').value)||12,height:parseFloat($('ht').value)||280,align:$('al').value,flip:$('fl').checked}); }
        function triAngle(a,b,h){ if(!(a>0&&b>0&&h>0))return null; if(h>=a+b||h<=Math.abs(a-b))return null; var c=(a*a+b*b-h*h)/(2*a*b); c=Math.max(-1,Math.min(1,c)); return Math.acos(c)*180/Math.PI; }
        function curInterior(){ if(S.ang==='custom') return parseFloat($('cust').value)||90; if(S.ang==='tri'){var t=triAngle(+$('ta').value,+$('tb').value,+$('th2').value); return t===null?90:t;} return parseFloat(S.ang)||90; }
        function sendDir(){
          if(S.mode==='mouse') return post('wall_dir',{mode:'mouse'});
          if(S.mode==='axis')  return post('wall_dir',{mode:'axis',axis:S.axis});
          var o={mode:'turn',side:S.side,interior:curInterior()};
          if(S.ang==='tri') o.tri={a:+$('ta').value,b:+$('tb').value,h:+$('th2').value};
          post('wall_dir',o);
        }
        function render(){
          document.querySelectorAll('#axes .chip[data-axis]').forEach(function(b){b.classList.toggle('on',S.mode==='axis'&&b.dataset.axis===S.axis)});
          $('mouseChip').classList.toggle('on',S.mode==='mouse');
          document.querySelectorAll('#sides .chip').forEach(function(b){b.classList.toggle('on',S.mode==='turn'&&b.dataset.side===S.side)});
          document.querySelectorAll('#angles .chip').forEach(function(b){b.classList.toggle('on',S.mode==='turn'&&b.dataset.ang===S.ang)});
          $('customBox').style.display=(S.mode==='turn'&&S.ang==='custom')?'block':'none';
          $('triBox').classList.toggle('show',S.mode==='turn'&&S.ang==='tri');
          var t=triAngle(+$('ta').value,+$('tb').value,+$('th2').value), o=$('triOut');
          if(t===null){o.textContent='المثلث غير صالح (الوتر لازم يكون بين فرق الضلعين ومجموعهما)';o.classList.add('bad');}
          else{o.textContent='الزاوية الناتجة = '+t.toFixed(1)+'°';o.classList.remove('bad');}
        }
        document.querySelectorAll('#axes .chip[data-axis]').forEach(function(b){b.onclick=function(){S.mode='axis';S.axis=b.dataset.axis;render();sendDir();}});
        $('mouseChip').onclick=function(){S.mode='mouse';render();sendDir();};
        document.querySelectorAll('#sides .chip').forEach(function(b){b.onclick=function(){S.mode='turn';S.side=b.dataset.side;render();sendDir();}});
        document.querySelectorAll('#angles .chip').forEach(function(b){b.onclick=function(){S.mode='turn';S.ang=b.dataset.ang;render();sendDir();}});
        ['cust','ta','tb','th2'].forEach(function(i){$(i).oninput=function(){render();if(S.mode==='turn')sendDir();}});
        ['th','ht','al','fl'].forEach(function(i){$(i).onchange=sendSettings;$(i).oninput=sendSettings;});
        $('len').oninput=function(){ post('wall_pending',{len:parseFloat($('len').value)||0}); };
        function addSeg(){ var v=parseFloat($('len').value)||0; post('wall_add',{len:v}); }
        $('addBtn').onclick=addSeg;
        $('len').onkeydown=function(e){ if(e.key==='Enter'){e.preventDefault();addSeg();} };
        $('orgBtn').onclick=function(){post('wall_origin');};
        $('undoBtn').onclick=function(){post('wall_undo');};
        $('finBtn').onclick=function(){post('wall_finish');};
        $('closeBtn').onclick=function(){post('wall_close');};
        $('exitBtn').onclick=function(){post('wall_exit');};
        window.DolaWalls={
          setSettings:function(s){ $('th').value=s.thickness; $('ht').value=s.height; $('al').value=s.align; $('fl').checked=!!s.flip; },
          setState:function(s){
            $('sSegs').textContent=s.segs; $('sTotal').textContent=s.total_cm;
            $('sPend').textContent=(s.pend_cm===null||s.pend_cm===undefined)?'—':(s.pend_cm+' سم');
            $('undoBtn').disabled=!s.started; $('finBtn').disabled=!s.can_finish; $('closeBtn').disabled=!s.can_close;
            if(s.clear){ $('len').value=''; if(s.started) $('len').focus(); }
            if(s.msg){ $('msg').textContent=s.msg; }
            else if(s.near){ $('msg').textContent='⭕ اضغط الآن لإغلاق الغرفة تلقائياً'; }
          }
        };
        render(); sendSettings();
        if(window.sketchup&&window.sketchup.wall_ready) window.sketchup.wall_ready('');
        </script>
        </body>
        </html>
      HTML
    end
  end

  # ============================================================================
  #  تجهيز القوائم في Extensions (Plugins) وقائمة الكليك يمين (Context Menu)
  # ============================================================================
  unless @dola_core_menus_installed
    @dola_core_menus_installed = true

    begin
      plugins_menu = UI.menu('Plugins')
      sub = plugins_menu.add_submenu('مكتبة محمد عادل — الشريط والأدوات')

      sub.add_item('🏛️ فتح معرض مكتبة محمد عادل (3D)') { dispatch_core_action('open_library') }
      sub.add_separator

      sub.add_item('🧱 رسم الحوائط (غرفة بالقياسات)') { dispatch_core_action('draw_walls') }
      sub.add_separator

      sub.add_item('👁️ إظهار شريط الأدوات (حسب الوضع المختار)') { show_tools_bar }
      sub.add_item('🙈 إخفاء شريط الأدوات') { hide_tools_bar }
      sub.add_separator

      sub.add_item('📱 اختيار الوضع: سلايدر جانبي عائم (Slider)') { set_bar_mode('slider') }
      sub.add_item('🧰 اختيار الوضع: تول بار سكتش أب (Toolbar)') { set_bar_mode('toolbar') }
      sub.add_item('✨ إظهار الاثنين معاً (Slider + Toolbar)') { set_bar_mode('both') }
      sub.add_separator

      sub.add_item('⚙️ خيارات الوحدة المحددة (Component Options)') { open_unit_options_dialog }
      sub.add_item('👁️🪵 بيان اتجاه الثمرة لكل القطع (شاملة الضهريات)') { DolaWoodGrainManager.toggle_show_all_grain_indicators! }
      sub.add_item('🪵🔄 أداة قلب ثمرة الخشب فردياً (قطعة بقطعة)') { DolaWoodGrainManager.activate_single_part_grain_tool }
      sub.add_separator

      sub.add_item('🎨 مستويات وخامات المطبخ') { open_kitchen_materials_tool }
      sub.add_item('🚪 تبديل تصميم الضلفة') { open_door_style_dialog }
      sub.add_item('🪚 حفر مجرى الليد (LED Groove)') { open_led_groove_dialog }
      sub.add_item('🧲 أداة اللزق جنب بجنب (Side Snap)') { activate_click_side_snap_tool }
      sub.add_item('🌐 ترجمة أسماء القطع للعربية') { run_arabic_part_translator }
      sub.add_item('🔢 ترقيم الوحدات تسلسلياً') { open_serial_numbering_dialog }
      sub.add_item('📄 إنشاء تقرير الوحدات') { open_units_report_dialog }
      sub.add_item('💰 لوحة التسعير وعرض السعر') { open_pricing_studio_dialog }

      if respond_to?(:reload_core_rb_from_github)
        sub.add_separator
        sub.add_item('🔄 تحديث ملف الأدوات (core.rb) من GitHub') { reload_core_rb_from_github(true) }
      end
    rescue => e
      puts "Menu setup error: #{e.message}"
    end

    begin
      UI.add_context_menu_handler do |context_menu|
        sel = Sketchup.active_model.selection
        if sel && !sel.empty?
          dola_ctx = context_menu.add_submenu('مكتبة محمد عادل')
          dola_ctx.add_item('⚙️ خيارات الوحدة المحددة') { open_unit_options_dialog }
          dola_ctx.add_item('👁️🪵 بيان اتجاه الثمرة لكل القطع (شاملة الضهريات)') { DolaWoodGrainManager.toggle_show_all_grain_indicators! }
          dola_ctx.add_item('🪵🔄 أداة قلب ثمرة الخشب (قطعة بقطعة)') { DolaWoodGrainManager.activate_single_part_grain_tool }
          dola_ctx.add_separator
          dola_ctx.add_item('↻ تدوير الوحدة 45°') { activate_rotate_tool }
          dola_ctx.add_item('⇆ قلب يمين / شمال') { activate_flip_lr_tool }
          dola_ctx.add_item('🧲 لزق جنب بجنب (Side Snap)') { activate_click_side_snap_tool }
        end
      end
    rescue
    end

    # تطبيق تفضيلات شريط الأدوات تلقائياً عند التحميل
    UI.start_timer(0.4, false) do
      begin
        apply_bar_preferences
      rescue
      end
    end
  end

end

MHDESIGN = DolaSmartLibraryPlugin unless Object.const_defined?(:MHDESIGN)