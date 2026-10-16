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
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :walls,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="15" width="9" height="5" rx="1" fill="#d97736" stroke="#f8fafc" stroke-width="1.5"/><rect x="13" y="15" width="9" height="5" rx="1" fill="#d97736" stroke="#f8fafc" stroke-width="1.5"/><rect x="2" y="9" width="5" height="5" rx="1" fill="#d97736" stroke="#f8fafc" stroke-width="1.5"/><rect x="8" y="9" width="8" height="5" rx="1" fill="#f5c84c" stroke="#f8fafc" stroke-width="1.5"/><rect x="17" y="9" width="5" height="5" rx="1" fill="#d97736" stroke="#f8fafc" stroke-width="1.5"/><rect x="4" y="3" width="8" height="5" rx="1" fill="#f5c84c" stroke="#f8fafc" stroke-width="1.5"/><rect x="13" y="3" width="7" height="5" rx="1" fill="#d97736" stroke="#f8fafc" stroke-width="1.5"/></svg>'
    },
    {
      :id      => 'component_options',
      :title   => 'خيارات الوحدة',
      :short   => 'خيارات الوحدة',
      :tooltip => 'فتح نافذة خيارات ومقاسات الوحدة المحددة + الخلع والعمود (بديل Component Options)',
      :group   => 'main',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :gear,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3.5" fill="#f8fafc" stroke="#f5c84c" stroke-width="2"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" stroke="#f5c84c" stroke-width="1.8"/></svg>'
    },
    {
      :id      => 'wood_grain_show_all',
      :title   => 'بيان اتجاه الثمرة',
      :short   => 'بيان اتجاه الثمرة',
      :tooltip => 'إظهار/إخفاء علامات اتجاه الثمرة لكل قطع الوحدة شاملة الضهريات (تظهر علامتها فوق الوحدة) مع إمكانية التعديل الفوري',
      :group   => 'grain',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :grain_z,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="3" width="16" height="18" rx="2" fill="rgba(180,110,50,0.35)" stroke="#f5c84c" stroke-width="1.8"/><path d="M8 5v14M16 5v14" stroke="#fde68a" stroke-width="1.4" stroke-dasharray="2 2"/><path d="M12 5v14" stroke="#ffffff" stroke-width="2.2"/><polyline points="9.5 7.5 12 4.5 14.5 7.5" stroke="#ffffff" stroke-width="2"/><polyline points="9.5 16.5 12 19.5 14.5 16.5" stroke="#ffffff" stroke-width="2"/></svg>'
    },
    {
      :id      => 'wood_grain_single_tool',
      :title   => 'قلب ثمرة قطعة (يدوي)',
      :short   => 'قلب ثمرة قطعة',
      :tooltip => 'أداة تفاعلية بكاشف بصري لقلب ثمرة أي قطعة خشبية بين أكبر مقاسين (الطول ⇄ العرض) بدون لمس السماكة',
      :group   => 'grain',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :grain_flip,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><path d="M7 19V5" stroke="#f5c84c" stroke-width="2.4"/><polyline points="4 8 7 4.5 10 8" stroke="#f5c84c" stroke-width="2.4"/><path d="M5 17h14" stroke="#ffffff" stroke-width="2.4"/><polyline points="16 14 19.5 17 16 20" stroke="#ffffff" stroke-width="2.4"/><path d="M11 8a5 5 0 0 1 5 5" stroke="#fde68a" stroke-width="1.8"/></svg>'
    },
    {
      :id      => 'rotate90',
      :title   => 'تدوير الوحدة 45°',
      :short   => 'تدوير 45°',
      :tooltip => 'أداة تدوير أي وحدة 45 درجة حول مركزها بالضغط عليها',
      :group   => 'transform',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :rotate,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36" stroke="#f5c84c" stroke-width="2.2"/><polyline points="21 3 21 8 16 8" stroke="#ffffff" stroke-width="2.2"/><text x="12" y="13" fill="#ffffff" stroke="none" font-size="7.5" font-weight="800" font-family="Tahoma,Arial,sans-serif" text-anchor="middle" dominant-baseline="central">45°</text></svg>'
    },
    {
      :id      => 'flip_lr',
      :title   => 'قلب يمين / شمال',
      :short   => 'قلب يمين/شمال',
      :tooltip => 'أداة قلب ومرايا الوحدة يمين/شمال بالضغط عليها',
      :group   => 'transform',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :flip,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="3" x2="12" y2="21" stroke="#f5c84c" stroke-width="2" stroke-dasharray="2.5 2.5"/><polygon points="3,18 9.5,6 9.5,18" fill="rgba(255,255,255,0.25)" stroke="#ffffff" stroke-width="1.9"/><polygon points="21,18 14.5,6 14.5,18" fill="rgba(245,200,76,0.45)" stroke="#f5c84c" stroke-width="1.9"/></svg>'
    },
    {
      :id      => 'snap_side',
      :title   => 'لزق ومحاذاه ذكي (Snap)',
      :short   => 'لزق ذكي (مغناطيس)',
      :tooltip => 'أداة المغناطيس الذكية: اضغط على جنب/وش/ظهر القطعة ثم اضغط على مكان الحائط أو جنب/وش القطعة الأخرى للزق والمحاذاة بدقة',
      :group   => 'transform',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :snap,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9v5a6 6 0 0 0 12 0V9" stroke="#ef4444" stroke-width="4.2"/><rect x="4" y="4" width="4" height="5" rx="0.8" fill="#f8fafc" stroke="#f5c84c" stroke-width="1.4"/><rect x="16" y="4" width="4" height="5" rx="0.8" fill="#f8fafc" stroke="#f5c84c" stroke-width="1.4"/><line x1="12" y1="2" x2="12" y2="5.5" stroke="#f5c84c" stroke-width="1.8"/><line x1="9.5" y1="3" x2="10.8" y2="5.8" stroke="#f5c84c" stroke-width="1.6"/><line x1="14.5" y1="3" x2="13.2" y2="5.8" stroke="#f5c84c" stroke-width="1.6"/></svg>'
    },
    {
      :id      => 'classic_door',
      :title   => 'تبديل الضلفة',
      :short   => 'تبديل الضلفة',
      :tooltip => 'تبديل شكل وتصميم الضلفة (سادة مودرن / شيكر كلاسيك / زجاج / مقبض مخفي)',
      :group   => 'kitchen',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :door,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="2.5" width="14" height="19" rx="1.8" fill="rgba(245,200,76,0.12)" stroke="#f5c84c" stroke-width="2"/><rect x="8" y="5.2" width="8" height="5.8" rx="0.8" stroke="#ffffff" stroke-width="1.4"/><rect x="8" y="13" width="8" height="5.8" rx="0.8" stroke="#ffffff" stroke-width="1.4"/><circle cx="17.2" cy="12" r="1.3" fill="#f5c84c" stroke="none"/></svg>'
    },
    {
      :id      => 'hand_groove',
      :title   => 'حفر ليد (LED Groove)',
      :short   => 'حفر ليد LED',
      :tooltip => 'إضافة أو حفر مجرى بروفايل الإضاءة الليد في الوحدات العلوية أو الدواليب',
      :group   => 'kitchen',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :led,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18h6M10 21h4" stroke="#ffffff" stroke-width="2"/><path d="M15.09 14c.18-.98.65-1.74 1.41-2.5A4.65 4.65 0 0 0 18 8 6 6 0 0 0 6 8c0 1 .23 2.23 1.5 3.5A4.61 4.61 0 0 1 8.91 14" fill="rgba(245,200,76,0.32)" stroke="#f5c84c" stroke-width="2"/><line x1="12" y1="1" x2="12" y2="3" stroke="#fde68a" stroke-width="1.8"/><line x1="4.2" y1="4.2" x2="5.6" y2="5.6" stroke="#fde68a" stroke-width="1.8"/><line x1="19.8" y1="4.2" x2="18.4" y2="5.6" stroke="#fde68a" stroke-width="1.8"/></svg>'
    },
    {
      :id      => 'kitchen_materials',
      :title   => 'مستويات وخامات المطبخ',
      :short   => 'خامات المطبخ',
      :tooltip => 'إدارة وتعديل أسماء وألوان ونقشات الخامات للمستويات والـ CutList',
      :group   => 'kitchen',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :palette,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.2" fill="rgba(255,255,255,0.06)" stroke="#f5c84c" stroke-width="2"/><circle cx="15.5" cy="16" r="2" stroke="#ffffff" stroke-width="1.6"/><circle cx="7.5" cy="10.5" r="1.7" fill="#f43f5e"/><circle cx="11" cy="6.8" r="1.7" fill="#f5c84c"/><circle cx="16" cy="8.5" r="1.7" fill="#38bdf8"/><circle cx="8" cy="15.2" r="1.7" fill="#4ade80"/></svg>'
    },
    {
      :id      => 'serial_tool',
      :title   => 'ترقيم الوحدات',
      :short   => 'ترقيم الوحدات',
      :tooltip => 'ترقيم وحدات المطبخ والدريسنج تسلسلياً للتقارير والـ Cutting List',
      :group   => 'utility',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :serial,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="6" r="2.2" fill="#f5c84c"/><line x1="11" y1="6" x2="20" y2="6" stroke="#ffffff" stroke-width="2.2"/><circle cx="6" cy="12" r="2.2" fill="#f5c84c"/><line x1="11" y1="12" x2="20" y2="12" stroke="#ffffff" stroke-width="2.2"/><circle cx="6" cy="18" r="2.2" fill="#f5c84c"/><line x1="11" y1="18" x2="20" y2="18" stroke="#ffffff" stroke-width="2.2"/></svg>'
    },
    {
      :id      => 'unique',
      :title   => 'جعل الكمبوننتات فريدة',
      :short   => 'كمبوننتات فريدة',
      :tooltip => 'فك ارتباط جميع الكمبوننتات المحددة أو في المشروع وجعل كل منها فريداً (Make Unique)',
      :group   => 'utility',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :unique,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><polygon points="12,2.5 14.8,9.2 21.5,12 14.8,14.8 12,21.5 9.2,14.8 2.5,12 9.2,9.2" fill="rgba(245,200,76,0.35)" stroke="#f5c84c" stroke-width="2"/><circle cx="12" cy="12" r="2" fill="#ffffff"/></svg>'
    },
    {
      :id      => 'component_translator',
      :title   => 'ترجمة أسماء القطع',
      :short   => 'ترجمة القطع',
      :tooltip => 'ترجمة وتعريب أسماء جميع القطع الداخلية للوحدات لتظهر بالعربية في الـ Cutting List',
      :group   => 'utility',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :translate,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3" width="11" height="10" rx="2" fill="#f5c84c"/><rect x="10.5" y="11" width="11" height="10" rx="2" fill="#1e3a8a" stroke="#ffffff" stroke-width="1.6"/><text x="8" y="8.5" fill="#091226" stroke="none" font-size="8.5" font-weight="900" font-family="Tahoma,Arial,sans-serif" text-anchor="middle" dominant-baseline="central">A</text><text x="16" y="16" fill="#fde68a" stroke="none" font-size="9.5" font-weight="900" font-family="Tahoma,Arial,sans-serif" text-anchor="middle" dominant-baseline="central">ع</text></svg>'
    },
    {
      :id      => 'report',
      :title   => 'إنشاء تقرير الوحدات',
      :short   => 'تقرير الوحدات',
      :tooltip => 'إنشاء كشف وتقرير شامل بجميع الوحدات ومقاساتها وخاماتها مع إمكانية الطباعة والتصدير',
      :group   => 'reports',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :report,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="4" width="14" height="17" rx="2" fill="rgba(255,255,255,0.08)" stroke="#ffffff" stroke-width="1.9"/><rect x="8.5" y="2" width="7" height="4" rx="1" fill="#f5c84c"/><line x1="8" y1="10" x2="16" y2="10" stroke="#f5c84c" stroke-width="2"/><line x1="8" y1="14" x2="16" y2="14" stroke="#ffffff" stroke-width="1.8"/><line x1="8" y1="18" x2="13" y2="18" stroke="#ffffff" stroke-width="1.8"/></svg>'
    },
    {
      :id      => 'pricing_launcher',
      :title   => 'لوحة التسعير وعرض السعر',
      :short   => 'لوحة التسعير',
      :tooltip => 'حساب التكلفة وألواح الخشب والأمتار وإصدار عرض سعر تفصيلي للعميل',
      :group   => 'reports',
      :rgb     => [15, 28, 58],
      :bg_grad => 'linear-gradient(135deg, #101f42 0%, #0a142c 100%)',
      :symbol  => :pricing,
      :svg     => '<svg viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="2" x2="12" y2="22" stroke="#f5c84c" stroke-width="2.6"/><path d="M17 6.5H9.8a3.2 3.2 0 0 0 0 6.4h4.4a3.2 3.2 0 0 1 0 6.4H6.5" stroke="#ffffff" stroke-width="2.6"/></svg>'
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
    dir = File.join(base, 'toolbar_icons_v8_clean')
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
    'library' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAACeklEQVR4nKWTSWtUQRSFv1tV773uJG0boyI4QlREUEMGCRqcQA26cuFWEOMPcKkbcaGCf0Hj0oUBBTeGIA4oEogRl+KAOIGobRszvHR31bsuOq0xuvOsqi53qHPqXFFFRFDVszHjj/vKU6E5dhpCsMI8WBu06sW2tthpunY8EjlXVUWcCKppf/vFUyODw08qnSEgCKBAo0XjrOAserB75Kmm/SdEhl871aP5C6c+XDl/bXr3zI9Qxqtg5hUq/HEX0bEXfrfCFdWjhxzPSr0jTypdM998+eCe5uj44UXJxKRiDTgLRqDiIcuUQsFwZ3S6enVo8tvIeKXrzLNSrytP0OIzRDyyeU1k3nxuigZv14id0LcFli8Wrj9QjGTs64zZ2l4LkqmEgJQnaHGxM6FBueaVt588r957otiwepmQVoSXHxWjgXUrPKuLis4xip0JJoRfUiECcSTEOYNoDcETO0XDLPnEkIsEM+9vQkAMC2CMwU/OsHdXDzt7O8glOQaOHSGtVOsTFuYvDIgIWaXKxvVraV+3iihy7Ni+leD9v+pxCwNZluGKBW7cuktpGzRHKecuXSafz6GqfzUw1v7SBFUIQcEYvnz9Tqk0gfeBt+8+AUII9ZwGrEVd1WdWtW40ZyHOCUkkJHFEoVloysGiQoIhI58T4ui3Uas+s661yJRzqBr0YynoyT4fNq1UrAkU8vWmPRvqRlq+1HNvLGQqopFFW4tMOTraRg90p+Njz/2eoTvT5ZsPZ2p2TtqQ1Z/s7Jw+CrVZ1aaldsn+7uQ+HW2jTmQo1bR/QJTB4bFKZ9Wr1GnKH7vUECmJRPt7kgenLxQHRIZS+d91/gnLWDVLJwH0HQAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAADtElEQVR4nLWWTWhcVRTHf+e+r8xM08wk1VBD0WLcBESS6KIggrZFumuJcaGg2AqWlJgWV6IwDHThsjGIdFE/ttbQjSCl4kJwIabNqnEzLkpIoM1XfZlJ3sybd4+LN5N+mEkb1AOX9zj3vvM/5/zvOecJTVEtGpGSTd9H90BN2JUEKnK58rAtAdBi0UipZPXWkRfnfo/fmy03hlUREVSVHYFaZ0TQwX73+sBL3tfy9E8zLZvSQtPy0RNTX1UuTk5vFBaWbay7cx8B+vYZb2IkuzZ+cs8H0n/timrRpBEsvD409cX6jxNTYcZxJA58TCPZHYRjoB6LTRL1Jsf3bo6f6TwmfVdvuKrI3HT91IXparfjEGY6cHxXJJcxD+ZGQBXUgnGAh/CjGmw4VjYj4gvT1e7DQ8EpVWZdGM3NlheHF5ZtvTMr5u6a1U/fLwRn3swHS0sJnpvaUgXfFRwHNmuKkVSfJFDoMszMRY3jH9+udubELCzb+my5PjzAaM6FmqgiLTK1oezvFrn6G/LRlwlPFgQF1kIYfcXw/EHhk28Snuhq6teVEy8L775mRK0Cwj17NXG3y6cqhFVleVW3vF8NYXVdCTdgaUWxtqlfV1ZCJbHbc7MtQIs08cD3munxBc9N9Y4HgQdW033Ppe1dNu0AWpG0Vhw30CaxSWJpJPaB/XayI0BLRIR8VycigrVKNpshm82gO1l+LAAR4rhBvquT7779jJ6ePHeW1zg39jbnxt5ide0vXNf5FwCtQ8ZwoK8X1zU0Ggk9PXl6urtI2jF7n7Ql+V4QQj2O+fmXGaKoTmeHz80/yizlBd/3mmlq3652BlDFdR3CsMLYh+d551gHB5/Lc/7zaboLQiG/l5XQslMiHhlBKwo/27HVXk3gEwQp4Y+StgAiYAxbLQHSniwCImnZm+YZ2aGhtwWIamArShik97xegY0IojokFSX0U32tqlQjbVsLbjqJaC0QIYqFk8ddXngWMkHqXtyA3gLsyQiHBhx8LzVQi+GZ/YbF2xGIYCQdQiIoBOrC5epg/6vX+/aZ4fk7Nsp1GefSD+v1X29GDfe+0AWIE7AWAv+f1Tt/J9FcTqS6qcmBXscf7Pevw+WqK4Lqgn/p7EjujYmpMKNIXF5o2Lk/69sQ03xukw7HNwhokuCdHcmtDhzyL4mgbnNk3tDy0dOgFye/3ygsrtg4k32sGnxAnuppjczcaem7ekO1aFyRktVi0Uh/6YreOjJ/eMj/D4b+tXToS8luffx//bb8Dazm0tsbc/RLAAAAAElFTkSuQmCC' },
    'walls' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADM0lEQVR4nG3Tz2tcVRQH8O+59755k8n8yJtJYiZWY6vVghZCk5K2iA2ISVAEFw2loguxC3HXpYKI0Na/QWhxIWQTKrjRWEEcLDHGqcRi0bbTRJmkk2lMX+bXm5n37r3HRVMs6tmc1Tkc+J4PMYOIwMwfxnB18Xm/aXpjio0xkvBQSWk41CS9pGxh7NgVoo9CZpAiAnN75smPz1y+uFAMD1lLhIdGmRkEAggAA0oAU+OXr3J75m2ihduKebbn/Jn1C+fmguNBreOj2wbA/6xwXEBrgA0AYkDy8o3UcSZcYJ59WWFl+8jXxXAsqHX85w6OyMOHx5SxfP9sQbhZWrX5/CClUykCgEbNt/OfF/yF5e7Y+yvbR5Rfk0ljiSgM6NjRCfXJ2ZEE31kBCQfoG8Cn356MJuJbarj6PUknhrVHp+2lr4r1KArJr8mkkoqNEARmjUazCdTLMEEZxhJcaiIIHuNWq8qd6hpBSASJMbahhiCCVGyUJElRFCEzOExpL4eF0mS0sbaX016WUk0Pd/2b9veRcf0rPYF0n0f1LnjokQxp60OSJOG6EvV6g6deeck5P5VJ7F/9Qt3dMXagWRb7rs+pU4kVdzJacio7IadrJfGqXHbeeuM1t95oca8rIR5EJYVEfP0n5CqLNDSQoX5dFbmNAvX8UaBsZYmGcmmRCzdFf3WJFAF2N2sFDThODBt3KvbHPa9rO2xRurZh3b3jujz6DLU7XfQN5lH6pWycxyfQ8F6g25euWFcRNAClJLG1BsneBA3bTeFv/IkTeceNRVsodvJ6u2152r3unBjqxHRQQToxiL5kgqxlKEGsukxSRwZeLktP/1UQ6yvfQPR6SIkQ9559V6bjHu+7MSe26gEQdbFn/wHk+6cp1AytSSo3JZrxuMOblaq9Njht6hOjIOWgxyHc2lbmXqvBvx18h1rtEGwtfC+DtS9XTY8rWXmiqXDAXZp9Mfvz2c8WJ0cLRR+OIjADICAMALaA23v/rYkAbTiuut4Hb2a/w1PukiKab/POzGkiXFz4oX0oMpoewIFQu6K6ux1wJPHM0WThvXOZ00Tzbfp/zsIYg39xBofa/ofz39OrlIN8KYykAAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFcUlEQVR4nLVWWWxVVRRd+9x73333TaXllZkOWEGRyKgfIo21ZYp+qEjiiFOMGm0M+uGHH7UhwR8TxeoH0WDEmBCGEEPC4BQNREzsgCm0VItS6GTB19f37n3v3eGc7cdrwVKCMdH9dXL2OWudvdfO3ocwbsxNgqhZFdebY4BL+FdmMtE++1osAgBuahLU3Ky4r2FV10/+Mx29wUpmEBGYGTckmjhDBF5eo7ctvsP4hCq/bp3ApAk27l37YMsue+eOA7nS/kvS/wfcqURgzCvXjFc3RUYbn429QDVfHWRuEsUIBtavaPkwe+TVlowlNPhRSxeaIICnoIAVQ7GCpmmT/ERAJieVDJSxozGRb3w5vpHmHmvXmUFdB7zn3jvglGkaMtGI0LIZh1U+V0wgXwUHAzBNaJoOmXPGHVcPWKUJjaD77+53yupXmM8xo0MHNkc7egdXDlxWXsTSRS7jYMPaWqN2zWrdl4AoBgmlGIYucKa7Sw4ODvPadXV6IAFBBAZgkORPP9vn/3ruvBpKhbyOXm/lYmyO6oBLzCBmkEYEP+dwQ0OdsfWlZAgXTgJmDGAGAh9IzsbR4/VB6+kB+UZdwky1fw8zNg2+ncK0+i042dEtz3R2wUqYVCwOl/QpagmC7bjsnj+OTM8X0MPTAGbIwEV8VjXGRh9ix/U41fotzn2zB2ZJObz0MKpm3gpPThV/CgGBEIuaZM6qQblzO2DGi47AA2bMR6I/QdFwgcoWLER+YDlCiekIMnOQrKiGaVy4MYFUEhwEaP+5M/jy5HrKO48iYpnk+QEkg8ODIRxvPS1/7e1Txxbf57u3LSDDMOD5PlsDEfzW06MgJr9ZAAAJgpQSkWiEDh3+PPrkA/eG8mMOwmYMze/sLoxcLqgQCxSyLlYvW6g//XBDiJXEj53ngl17j3pWJAo7PYr3tr1urbn7Tr2QdVgbL44rdCwlzEgJ7loQN3BkO7ycjVn3N2L/8lV+/a0Jo+SHFnKVDiIgcAuYWVENuXQDReMlcp11xuj7bjcqn9yG5NwKYu8HEImpKWIAqZERdntOketkQbefh+sr/Dkyws7ZU+SxARBDeR7YzSFTvZpzrsejfb0Y6m5DvL8PgVT4exOYnDBWKJ9fRaJ2E9ycg+SiZaCvT2D67PmUrN0EDwaEEPAKOSRnzUEsH0eIxlC65C5UjF5G2cKl0MUv1xdZ6DrymVF8fLjdTZRvhIxK6G05DF28oPac7HfLkhvIyaQhZQArloCRDqGz84waGhpWH1VUuf70LTCOD+P3X84qLWwJZnWNBkrBCIdRu/xm3bIHKFAMgHDPaw+EbNvmSMTD4ZGsf7q7V7751Lrw6B9DWN1QA00spFzeZuV7SMytwd4ZMzzld0/VoEgQQ0XEE/6h7RSIEAiAVAqJwKeZVTdhwZwnhB1oXD30rVDf7YcRKwFLhVLdID9zCVWPvYVYaTmxDK6vATPgOA689CiKBAwQQXouIuk08iUFFFwXdmYMdjqFkGRAKUBo8DMp2NkspFLXamAygZiIGMpFWeUtFH68Gb4qtmCAIAMfJdOTiPSZCA2mkah9BFWzl8CwrOKrSEAWHJQsrYOmugAiFJu9yTqwz1l2c11bxezQyqHhVOHxrW/beqSUWF0tN2ZAQGH4Yh9nxzLceqpbsjYR4Xh9E0GTnThxos2vrEzEl9ZobcA+Z/LAeT9jcd72oCuB65gWMqHpGrx8vsh6rXmkYEWNlq2lhVeej22kqmPt+vjIbOeetS8C2PnBQaOs/7LyJl0vFhSYGWDAiptX9iaMAMxLaqHGh8KpV7ZEXqSqY+3MTUInalbc1CRoUfNB7mu4WL/C+A+G/lfFoU/N6srl/+vb8hfl7NORHrWD6AAAAABJRU5ErkJggg==' },
    'gear' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADJElEQVR4nH3TTWhcVRwF8HPuve+9efNmJk4nM0PAkmiKpdlYDIaghQpSiBERwfixaRfBKoSIxk0DrZpFk4U7K6JQIQUFoSuVYMhKsUhpSQ0KCtVimpaStpbpdD7evJl3799FuulCl2d5DudHEZCEiHzgY/3nA7WmjXwj1lrNwAAAkKSA1la6KXUxp1sYfeocudAVAQ0JkXhieOndtS++v5g8kVohQABAnDgoRQTeTgYERlOee3LtksQT0+TqFSMyFS7OXT998qvWwXZHaqSQAKmBxx72VCcRbG33nAAQQEQo65fTg0KcFpmaVNi4M756IRltx1KLQmEUkpmAYu9a9+1SNfr4nVJo76U2m6HkQjIKhe1YaqsXklFs3Bk3tTpyqQW1EhqSKx8NRL9f7brb/6RucMBX5aLHT49XoyivOFgx6sVj2y1NQWrBWh055Rtl7xekAPhjq+veOFz0R/Zk9Nj0ZuPAW3834ZGHX+vzr91OnROAamck3yhrrAVJQAjcu9mzWzdT9813jd5Lc1dbJ9/bG5aKWc4s/NKuN50MVrVq3OpZ5IwmAWtBow3QSUQGBwxPLVbzTz8emmffvtZanNubmV86EwA5DJRn1NH3f2qvL+/Jr53Znf/ws1rSjFMJAkAZDTgRZDxy3yO+zgaKcWKlf1eogCIAH+VSnql1IIl9Q74u5BScE2gDmCQBwkDxt82uHZ7crJ86Uc7OTvUHMwsb7WrlKEvFAl+eWW2/eqjibfzZsc/P3mgwVGp8xNftFmC0hhAALBCVjcpHmkdef8ivt528eeJcbK3FK4cq3ifH+8OzK41eVFDs9HaupjXEdFOn5f7NjAaHqkZ9+fXd3qMVrS4uD+cJ4te/OvbsSqO3q6Dpe2SnJyIAuqnTptiHptEQ6yipE7xwbLvlRKR1K5Ufl3fnR4Y8PTl7o5kpKHge6ZyIdRSjIcU+NA32l85PjMXr65fTZ1oxaqRAEUTOYP7zWqeQVWSo2O0BSVdEQMmGLE6MBT9gf+k8AUDiieGl+foDmEigFTuxDshnFR/EFFyaX+qbZrh6hf/LOQA0gHby35z/BSX5kQ8aqDm2AAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFoklEQVR4nLVWW2wV1xVd+5x53rkP27XBxSZFrfNQokYlBpUktEUFVFElLhScfKCkKi6BqDJO2sppA4nltGrVVKpCnKRQFaKQpq0gblArNSFEeQBVHgRQ8uF8xJUaGzsY/OD6znjmzsw5ux/X1y0mVO1Hztc5mj17zd57rVmHMLuYewRRr67s27NAmfB/LZuJDvnzcxEAcE+PoN5ezR+tWTZwMvnumcG0lRlEBGbGfwWqxhCBl7YYp65fbj5Nn3vl3WpOqqLx4NoNffv9vbv7Z2rPXlDJ/LwEQAiAGdD8CUBgNDdIs2tjZqpzS3YbtRx9gblHVCoY+cZNfU+WXuzqm3aFpMS1IapJmSsbpYEo0kwCcG1BRAAYIAKqeGEZWis2d3fmw87v59ZR05HTghk08Gbc8Vh/UCclEs+FnG0LxSlISlC5zGi9xjKO/aYp9+efNWZrskIwg4SsxAAgZpDnQkqJ5LH+oG7gzbiDGSSAdu/MYNw6Mq5jxyahVKUFUZl5QUFQGDGSQDMBWLkiY6y80TGnSpqDkmY/qMREZWbNgFKAY5MYGdfxmcG4FWj3BFAm5soXzA4NKmXs2FSw/76/Kdt6nS2v/oIl79mQtxBq1GQFnvpRvbtqmWvc+kXHOLG/Kdu1qWCrlEFUZWQ1X5mM+YNMUsaCWkk/3lzjNDQa9PwjC736GkkkgDfeDVOlgW/dmjG/c1vOKl5UKBQMdG8uOAdf85MLFxWbxqXkEP95YACWSRibUNz24LlgdDjmRVeZdPB1P168fmh6VcdoaXXHaGnh7cPTD/SNRzlPoOQrbn/4fDB6PtWWRZhPMGPeGakCUsU8Oa3ZqzHw+79Mx3f9ZCzI10Ps3Ga7OU/Sc0fC+NE9U2EQgR9/oMFd0miIYzEjTStUviIAM1CbFWQzcO/6nOWaoB88Phk11EP8re/q7LK2TglZgy137LO+3XkiePLZYnTPbTm7qz1v//V4kHieoGJwqUrm8AQBYaz5ifvr3Q/7F+e3teXtk+9F6YURrbZusO1lbTvkNFajmLaiYfku2tnR6JBSeOmdMLnxWlu+f6A5f/TXn83mM4JSVeHnZRVoBhbWCvGZZpMQMcKEAa1R8CRB1oETQDBDI4+854CIEcUMwyI0LzLJn9Y0v0VzR2bAtYi690yFa+4+6/e/4idfusaWTq0Uf3g5jCdO/5YLzjBybhFidC9+d3go1mzglhts+Y9/xvrr9476mx4aC/wZZikIrOdVwAAMQXhrIErTouIyCOvXZs0dd+bsR/dMhm07TgQPdXzPzmVs2nd4KH76UFz+6krP/NqKjPHI3onoteNBIvKSXIfm9HD5kAF4DtEMJBEB/qTiX2yvc2Yi5icOFKN1bw0llSiJVV/xzD/1LvA4ZZz8IFYyJ6mQFRQrvmTIlwmtHDMaayX1/3SBV6gxKCgp9HU3uFtvz1kvvR2mccz85RtsY+2KjMEpgwThmZ0NmeVbR0r/k9AMgzA2pfiXzxWj4fFEf7P7nH93z9hMWTG6N9fYu7bVOZ9vMsSuvRPRuh+eC4YmUv7VH4vR2KRiw/hEodlMBKbZZ8yANAi7ny+WD77qJ2fHU33sJOPw8SAZOLA437zIoC0/H585diJIKCdo5daR0scTSpsmEc/+vv+dz2YBHAqWtlinmuqFFZVZS1nRhGMTnS9qznuCMnlBBU+QH2q+WNLsWkRGXlJtTtD5i4odm0gQICUQlVk31QtraYt1CjgUGERgHrH23bfR29TVN+0GIeYMxzIqRiNAKPqa19z/cUkIwJ/RbDuEWIGt2bYQAUEIrRXM+zZ6k9ffbO0jAhuzlnmaB9duB/iKlgkA5yZUhUMCIJpvqYwlC6uW6W2npiOnmXuEQdSruadHUEvvC/zRmuHVN1lXNH2apUVVRMCVTP9oxfSpV8+9/GldW/4FkPjer0IhCskAAAAASUVORK5CYII=' },
    'grain_z' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAACv0lEQVR4nH2TT2hUVxjFz3fvfe/NvDxnnIxh8F+FakuplYopVESwIEqMtKu6ceHGTaEru2q7aGnBCtl0KQVFdOG2blpCCq1i0aBG3IgaCCiKlTHJ/HFmMu+9e+9xMYNCG3uWH+f++M7HPUJCREDy+xBz1/ammRvRSnkAgAEADVgHAHDeqyjUXYzv+Vvkh4yEGBGQKxNbT52YOTt9K9213HJwHgAEIgQAkAIIIQCqZY1DH8/cZnPiuMj0giGPFH/66smZkxe7+3pt1ziwN4nGShQPEWvFk4Iw8AqeXLGCS1d6/bkHdh+JM+SRSYM7S7tnbqXjvef58ueflQtTRwu2m8Z569lDu33y61JcfSu4cf7LxbUbtoRJ2JN3NwaFqV+Wlv+YS8e/vbO02zRaSKyFCCG1UaMW5judtkoQVya1bDkaIta6XzumHtWv5Xaxk45VRmIBJLeQRguJCY1yIgAB5DkRGKhSUlTt5/fs/F8X2snYelO/fznd9E4lXukgzzsEAYgAoVFOOQfBUCKAJ6FMgPrC3XT56aOs21y0j+/O9kUC0BHyyg04B1FYRfREEBUlCCPROpCouGa443+1KgAY2EmAJPiGx/8L8Daj9xakh8vSNxKU1q/xBKBEQHqMjNZMVExUEEZSqm00gIf8K4jWoMms1yQggwGyHOy96Ln1H+wv7Pj0i0oURapZf5p3nv3p8gzUMvCSQGa9VpUyOoEZxO31yW1vF6PN67yWJ5cyXb+ax+m8s/Pn0lqSy/vvxYUsJwkwMGCljI7BzursgY9W5m7et5+c/+1FoxiUitVSQ7wfwczPU4QEufiwKv80mXnI6V/b/bgajB4cjy5jZ3VWAIDNia2nfmyd/f16umup7cBXX8MPL6MH+T1RLSkc3lO4/c135eOydnpBVqtzFA7rDD0EDepsvVcm1F18+LrOLwHXj1259t3UIAAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAEKElEQVR4nOVWS2xVVRTda99z732fvpb3SptASwxQy0clgdYEJ6ABYgwhxmB14kDAACq1DE0MvjyNic6o6KCmwTgwkkCDSqJBUIgDGYhtGj4JyUMKpV/7XtvX972fsx3cVoikUEgcuZJzz73Jztpnn7vOXgc0C5EkAykdvLdVEVVADwVbgOP5f3OBiEiSSUYqpeXm1tarv7u7+tJeiwgBvDBq0UQAyfom9cfap80v8djZi3OcmMsm6W0vHTma7+o8UYwPZ7Xr+0KuP7uCOQDBmkTfIScig4lMBVqaYLPj5chk++6qfWg6c1IkyUEFQ89vOPL5zI8dR3JhpeACBMsk1C4yQASI1gIYEL8i4nvEdhSifQEzQCKFopbsjAhA4ntidrZXl9rfjr2AhtO9SoRwtcfZc7inkFAKOcsUozam8PX7dZEVDQqFnKOtsMXi5sWIb4IRXYbyzR5tRuKoFMvask24RHjj44nShctljxXcwz2FxJYN9h4R6mOitmhf2mkZmtBOLExcmNL6wCs14eaELh3vvnUjk100/esPI7d//i47GF35jq5/6iD6++vGTn11ZeCvTDz307fjg9nrucyHexORSlkoEiIemtBOX9ppIWqLMlEFIhSMu7Y6k/G8zGTFW7p6ebRcgWzc8+nixJLlJgzG5je76n2jjpY+3hh2xaLRsYrr+UTERFqI5viIKvPrxFCAaRrs5HP+sic3hqtqqlV2fNgrzExrNzfqrdm0I+YU8z6DYJnAfJq+rxC11qJCYUwMXKkc3ffMwJ8Xf8kXsqNe91ubb10++03OCkdZxBeR+TkWpHQRITsWZ6UUAKZQ9SIGmO7L/DAJiIjE9/8hFF8/IPoREjwq/icJABCUiaD7gWAoLLQTPjAKAHluRWbGxzzXKYtoj/KZEc8pz+j51X8H6kHkbrkk9SvW2auefb1qSfP6UCgWN7Yf7KwfvXGt4pbzElTiP1wFs8edmIhCkbAxNXLdbdq4vbqxeV0olqgzWl/cm5gev+Up22Q2GKKJ9DzK5cCJaG4QCVHEBiwTVCj5emhgsjQ+OOQcO/TaYDYz7fmapeeTg8PXLpzLjw0Vy1PZkscGKBoGSIgYgfkEX7YgaNfPfbbjveze2+M6xxBuXRNSxw4tDlmkXcfxyLRs+KWMrln9qh1KrDJGfvugaIZr2XMcATNFq5V6t3vK7/5+pgyGbqzj6lMfJb5Yu/PcgXsNx4TruxpPrLSN1cst5XlERCIAw3McrbUmK2RzcKpBhkGUyfr6fH/RNcDi+/cYTpKBVK+kt+0nkq7OE8X4SJbcS2lHLl0tz3nm7JODfyZOsJc0OxngSJRDS2rZ7NgZmWzfHd2PhtO9IklWQEpLMsloSp2Um1sHt2ywdvWlvRYCwVjgvUKESMvdpn8mMH2kNO4E/TfXlr8BybUuU5ZLim8AAAAASUVORK5CYII=' },
    'grain_flip' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADCUlEQVR4nI2TX2iVdRzGn+f7+73vcXvfdtw/jSZajiSDSFyaheaIyq1uuhGhm4q86EqoOyGICBWCLiIIi43oYrtZEhXLYaIZkUObCNWwycDVMMb+nO3snPOe9z3v7/ftYrIUuui5/z7web58qAqSUNV3Q0z8vL9UcVFzQVyagbgrxjjNcprW2FTR8/RP5HuZKmhJqCZ93afeOjd49mq6O3dg7hSBJVTvrlBAAWup/XvOXdOk7w1ybNqqHm46+fbswImh6sFaXUtQ5eY2I3MLuTcB6T3UWBIAvFP1njoxlR9UYkD18IuC64v7zl5Je5LUL8N7HHqyyY5/3hV3bwsEhMYRmaeZ5vVM40jYeh9YS1xp7Erag+uL+6S0gtg7kLli50OhGTzeET24NZAz72+O4kDZ1Rlx4MPe5lde7g5Xyw11SoqQjRwsrSCW0IrjnblEwKHvq+mNybr/+Ew5bWsPeHuupqe/mEyfP7DFHnvt0UJ5OVUakgRCK06cA70CLJC//5G6kQvVRi1THfxyObs979RBMfHbgnv92MXac/u7bM/jncZVcyUB50C7PrIHpEC0tQgNgajVkgRUgY0tIStQPT18I6MIwH/fY3FPCNAAFCgERtbYGs6jrXOjjJ6/1QA9TBTD+zvY67dC+DTD0tKi5vUV1OYXtDy/oOXFJa3MzfoH7u/kd19/Fm3p2iRutQJj1sqtMVARwq/W9IWXnrEn33mzqatDZey8jwlgjdUjipp44Knd5terY7b30KuVJJnS5tCqzXJvvAISWtyamfPjly/mR54thN+MrjaMACKCelLXh3dsN3t7HjOfDg6nf87M+h1bA1NLnbGtRVSMqDoT6vT0tDvxwWT95i+x+2SolIEEhEBW1207HzGXfrzc+Par0QaCIsKwWVqKrmKxq328f28ycW0q702yQunvckE/GtYsKHasb02SM38t+ZmbF7zEm7Ah8K19T4Q/YFf7uCVHEk36jlKxLpMRwPl7RSILIDZARLV/T9Ol46eKR8mRhP+lc2jVOWf+l87/APASkq0AnVvDAAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAEwklEQVR4nLVWUWwUVRQ9972Zndmd3YUugRYo1pAmxCpRKFowxkiEiB9+2AY/1GCksVSRtJoQVDCbTdRIQKECHxYLMTFRYhpMjCEU0SAhpRFb4ke/+oOIDYotnXZ3Z3bmvevHdusubbR+eJOXzHsz7557z7v3nSFMG3NaEGV08XlrHPAJ/8ksJvpy6k5fBACcTgvKZDRf27Ru+MfgxaGRsJEZ8wIgAjODiMBr6o2fGh40T1Ldt1dKPqmExiObnz5yYurjrt5c1a9/qIBBICplNw8gMGoXS7OjJTa+a3t8B9WfO82cFsUMbjyx9sixyTMdR9yokBRELQgCECgGM2Aa82Mr70NrxWbXrmR+187Ek7T87KBgBg33F1oP92ZTUiJwbEgpQJMTGs2PxiOZ7VXRqdsKUhAxg5hBQhBJIQjAzBozyIlCSongcG82NdxfaGUGGcBWZ2jkt8Ybt3TBtkgwA3mfsWKZIfa/nIrWLjXowpAXnrmUC5ILBWkNuH96DMWILIiQbUkoVeRQKcC2SNy4pQtDI4XGBmx1BODPREAANANEwKf7lsRqqw3ychon3locW1lnCr/AKBQU3uxYY7+99yG7psomd8xnKSspLPkDfBLlL6QAclnNnc8ssNbda8nxCYW8z4hFBfbvSEWZwSQIgae5ac0SOXCmOdHZdp/ljnmzQEpmlE9CDURjgk59ly0c/8r1+w7VxAHCps7RqVSVJCtCxEw42P2zf/DYVb+pqUZ+cXSjM5VV/Mlnw4XkIpu0riy5igyAIj2/j4c8Pq44VECoGBMTikdvhax1sWSTKYtSy2I0cHlUPffaD7k32lfbqUVRCkM9q3lmAQDFsiSz2AdEABmEiPn3VqUYfkEjWePQ5cGboRCELRtrzZwbsBSVEMadzoFilOXNdee8ZFpp2FGTXth9MXd9dFLbjkGKK7+cE2DeRoR8NssXL3thLGGTNMSsQOakSAgBwzRBJEEkYZgmTMOAUTEkpCC80r7NWlFXLXKuy4YxO95ZK0SE7FSOQ3eKA88CwAhv3+SxrAB0eRQSCCZ427PNkZ0vPW+1tu3O9V8aCJ3UQoDk3ABCSOQns7xly2PmIxua5LIHIkIIgXcO5KKmQYTy9IkQhAEvSCZoVX2dON/3efyDw8e9Q109XuAFM9VUASCJEHh5PLx+nbHn9VZrMhfAMAzsWQ17rkMmIgRBgLwfIGpF0Lj2fiNimcT5AjBdTRUAgQoRq1pIH3Z1e+8d6PH6u5cmAGB92+hkMl68h8rPyXVdvtB3Kn7PqpWiY/f73kdHT/q2Y0NIEzzdcEZRicAlAogIed9DdlLxpauREACyrstKEbj8DIgQ+gEPXLka7tm3Pzj/TV+YqKkmImbf52l/FhMzaLh349Gn9o61/XJTu7EopFKAEIScVyQmZhPNRZEQAr7vo1AIOZmME3OIXJ7VXdUy+fW7qe6Glu9fFUTghg2Rns4WZ0wpNrN5KCIwa2bHBhwbYF1qtcqhVMgR0+REwoFSIWfzUErB7Gxxxho2RHqIwMa0ZA7yyOZ2gCsk89+NQGAwFAiMu6tLkum00/Kzg8xpYRBlNKfTguozp/napuuPr43MiH5J0P8RYk7RP1cUfcromc3/12/LX/TWerKJ+qNGAAAAAElFTkSuQmCC' },
    'rotate' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADQElEQVR4nHXTz2tcVRwF8PO99773ZjK/+pqiLVUqFGMrTQ1NHYoKLaIw8Rel2gYVlTJuRFBaRKkWpJU0iy6kEYqLKLFqFAR3pWMEcSGlRhIKdtEfSVQaxWiHl4kz78277977ddGgq55/4MA5fIgZRARmftfHzPmHorYt+IqttZKkAgDAGkBKy9qQDIuyg8EHfiA6pplBigjMSW3z6KGpj879lO4whklKAjOgMwYD8D2CEARrGUqCh+6fmuWkVidqzCvm/fkThxfHRz7v7I4TjjyPRdZyDALWrlekJNFff2oHrVmsyZNjwTNXzW4mjDPvf0zhYnNXYzodjBMb9VYkNSPHw0+WvNeHK8G6shBgh44t8CdTOX16cjaVChR3g+jcdDr49sXmLhG1UMwMSHkkmpHFOwfX5E6+1pv/rNHOnnhrqTP05o32yYnF9MWXnvN/nm6U9z5V80TaJmZBUQtF4SthlQTMiuPhR4veq/sqwYP1xfbpL1fShd9TO389dpPfdHT14Tfa7Tjmgy8cCJxOWAiCr4QV1oKYAQB8eLice29iuXv9D+cglrG1b5N89pkhH2kEFQg8vu/lzuUrc9YvrSVjDKwFKalurh2uVzIsS/putpt5eUdb7u4XT++tedv775Xz1+bslV8WXdRq8bGRsa7zPayWQgAAA1Cr1xkHsDHcv22L3La1T27ccLuo7tyhjDHoCTykOoXRGYgIAKCsufnzjSXjutrxzns8Nf9boCfPTOrLcwu2OjigPjw11g03bhJRM+NCSRBJ/BchJVgSwJr547Mdfbwe5nzpCIXbcG3uV/fpF19rGd5JyysZv3KgEoRlQZwxiAApwUIbJzMLqLIQH3zVSs9f6pofz9xR3HNfoJxzcA7YfpeSZ9/fUHz+kYIfx8xSEDED2jipwgrangIbyy4sCaqP/B0frYe58aPr8mmX4RxQ6BH07XScHRprJkQEC2IlIcIK2goDvRdq1WRm5qrZE/3DkVREx081kxMTy+lAXyCUIrq0oG17KXNUksQA9+QorFWD7zHQe4EAgJPa5tEjrf8xKUJmGEmXmQHkfSLfJ1iLVUzB7JHRSp3yjXm6FWdYSUoBkIBJAdyC87+3WL7D8dHIWAAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFfElEQVR4nLWWe2wUVRTGv3PvPHd2FspDCq1FtD6CQoBSNSEqKsQ3PklEEk3VKCoFNJBo0NRG/UdjhBBf0fjWSEhDMCo2aIggJDzawh9U1CrIq6JA2e3Ozu7M3Hv8Y1soVDEmepLJzCT3/r6cc7/MN4S+Ym4SRM26/Dw7DZQI/6psJlqVP51FAMBNTYKamzX/OmNq57a4oaMrqWMGEYGZcUah/jVE4Mm1Rtv4evNdGvv19n4m9atx18zbV7yTf3N5S6HiwB8qHsglAgSV7+V2Ad13nVgDRvVIaS68M9XTeH/6Yapdt5q5SZQ7OHjdlBWv9q5duCLnCkmxa0OAy0ApgDBilEJmqD6iAAxHIuVIAmtozQABYQlaKzaXN2bCxsf8G6iqtd1gBnW2RA8sawmGSYlcyoVUChACSBTQm9U8ZrQhpl/lGhPPMyUJYE+30hvb88mun7LKcFPwUiYxA56jZKFI8bKWYNi1U+wHmNFhALO9jq5DdQeP6MixSSQKMARQjJjTtqAXl4xwG272ba9CopTV0BpwfQ3Ii/H5Nj9+8qUNxV2dRxQMgXQmTY7N4uARHXV0RXXjMdszgBIxg/oPU5bhyLiC1i6rTE+d5MoPWrLRR61B1Lk30okCxlZKumVazlyy9HnnmtueNr/6Znv8Rev6+MNPVkeOY4GZ+3glMk5xBACVAJ5N+HJZZfrCcbaYdu+B/Oa2MIFFcBxJUhC27Y711h2H1eurF0SfrVnp3TFrpnn++ePExyvXRMw8EAkx8MUQQCGv+LkHhzn1k1x5Q+OhYHN7mFSMkDTEl8QqQpDLse8RVYxM0eGjJX39TXPz2zt2qZqzx8ghvi8SlYCIBgsQAYWIMWa0Ke692bc/aMlGm9rCpGK4QYolomKMCRdfJOfPb7DjKIHSjLTvUM/xHN8199Hg+PEcV1VVkiolPIB/UkAQUAqZp092Db9C4v21+VhYBM1AqRRx2HNAj62pFg/dP8cOj3brfG+Bk0QhnfFo3579el7j0sLQjE9anzoiY2AHUIwJ55mymFX4YX+iLEdQqRRhwiXjZc3oK0T91IkSAO6Yc7eVD0LesGmrAoD00Ayt++a7WBqSUn6KShEPFugvKQHWQJwwpBQIgyJffukk4745t1qOm6KzRg6npxY/4rTv3K2+Xr+54Hkmaa2R8lxiZpzxkCGAvYeUdjISYysNUSwknB6aobffXRnV103PPfv88mL3b3/o+rprco8teqbgujZprSEI0FoPgp8ioDVgOILWd4SJShizprmmihiSAMsyYaZHUG8+4C3bdyozM5xSnnvCLIXSX5AHCTCQdgjf/xyp1o1BsuieCrtylClyecWSNGzPpQ2btiSPLni6YLs2ERSUKu+9ZJwl8TcSp4xIM2DZREteOxZGivnzVyq9IZ6knmMJJ0rDMg2kfZe0ZmR7NYd5zSueGO5ufa/KP2e0IaISQ9A/CDg2YffeSN24oDu4oMaUOz+u9htmZayMIygXKM5mE5YCmHlpyvjurTF+w11DrcdfPhr+uC9WjkM4zaUwykkEJio3qTSQ8QVt2VVMrn74UO9bS0em3nmhMhUcTdC5J1JJzDi32hSjqk36vTvhOYt/K3za2hulM4J03yf+JM9mA1gVTK69uq1qhKjbd1gVUy7JRAGZjKQdv0TqsgcP5mfUu8btV3rmxHGWlCbh253F5Ks3euI1G4P4WE5xZoggpcsWL4Ssa0ZJa3Kt1QasCs4YOEKUx5YPNCNhwOgbsAJAQMoTZBnl3DhD4DQJouZ27po5D+BBkUkAXEeAqGxloG8MAJQCCn1OIjDOGdUfmd48qmptZ24SBlGz5qYmQbXNq/nXGfuvnWL9B6G/rhz61KxPbP6/flv+BEGi6pay0OK6AAAAAElFTkSuQmCC' },
    'flip' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC0klEQVR4nKWTT2hcZRTFz7n3m/fe/Osw/m3jQslQKBShJqTGKnbjImkRqyULQSihFVqpxRY3WYkLDS7dt0tXgluHLkWktKQGpP6pxJXuLNNMZubNe+/7vusiMXHvXf8495zLPTQDSZjZJwk2fnhtMArNxFkIQakOcAAKD6gGKz2129Ix5k99T35amoGOhFm+1Fu/fvvWt/eKOe+NIAAQPhh8MGSpAGaAAc7Rlhdu37d86SLZ33JmK/XPb/x587OvxqcnuQ1EjAAYA+zZp1Se7ih//LUIUiNhsBhpGw/9aSNumq2cEWw+WuzfLeYneRh022CjTnZaAvjKFo+neunNVoIyWrclaNTJbhuc5GHQv1vMY/PRogy20ao8KI70EQSIvKjQO3ZU1aUc5wG92VQLvxvBx1228uBgGy1JnAQSsAiAQAgRrUaDN65dyoRmk8Ls/XOH0t5MTYrC8C9LAomTICHsngwAnCjyx9u2cv5s7dQrc7ozHKH0xOxhJ5ffaqfVJJrTfRwhgIL/jI8RWbPJ61dX06r0IAkVYJhHe+9Mu3Z4piZ5YUYcLN0XUKfceTy0d86frR3tvSA747GJCEhgWhhaMzVeOddO8nGEuIOl+wLRB2T1DB9dXU1DCDCzA0iAMIq4sNxOnzviGKZm3PMgqjBVQRxu2+qFlWThpeOqqmg1GwQAA5ClAlXg+dmUH7/bySw3qACqMFd6aggR2mzi9Vdfrv304GEQIX7+ZSvYnsU//qrig9+KUEwiXpxNtf2MsigNwUd13Q5HqrAgiX1wbW2clwGqwHgY7e03OsmRJ5QffvH35Muvh9MqRCSOGE1hSUI51MFIcKJzZ/lkutHI0B0Mo5VBMC2EoHLz9zJ8811eQch8aiw9MBzBshq7yyfTDZx48s5uznypt762fat/r5ir9v6CBMrK4INZIxPaXplqjra0kN5fW+9cZL2/xf9b538Arsh0PlevG64AAAAASUVORK5CYII=', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAEIklEQVR4nLVWz2tcVRT+zr3v57w3M0lqSWvqT4LSqWDTRLFVpMEWUUQNSSChi1i7sFHSNFu7GOY/aIkuXFRxHUKXEiooIpaiSRZKcZFFmzaLYE1iMvNm5r1373Exk8n8SqULD1x4997D+c733cv9HqEazFlBlNOV71EfKBMeK2wmmss31yIA4GxWUC6n+d6ZgTu/RueXV+J+ZhARmBkNQASA6+fVHCJwX6+xmHnF/Iae+f633Zq0i8YrZ4dmv85/dW0+6Hzwl4qa6lZZMrQGpGzdIzCOHJTm9HBic+pj/xPqvXmDOSsqDNbePjH75c5307PbrpAUuTZEa3HANgi2RbQdaKY2AhbL0FqxeW0qVZz6LPkO9SwsCWbQnVvhhavzhS4pEXkuJDOofkhBVCwwTvc51rdXDnpBoCFEYw4zyHMhpUR0db7QdedWeIEZJIBRb3kl7F97qEPHJqFUE3UiaK2hwxi2LdDhEbECYgU0s1AKcGwSaw91uLwS9gOjngDKtQ5aSQNxHCPp+9R95LAohxGXIiCZEvTkASmiiNtKtVevTC1a14dhSJS2tvnc2AfmwKvHZZAvgFmgKyVpeiRtl0NuYdEcjwSIYgWvM01TkxN2uRQyEUFKYHNH8eigZw5kHKNYOY/HBzAMA8HWPzw+PmQ+1XNYbOfzENVKsQI6fEkzIyk7DtvL9J8AURzD70jR9OSEw8wQYq+KlMBWXvHQoGe+nHFkEPC+LNou73Z/bnzIfOloryCiWve7ESvATUrMjD6aRVuASvdpujT5kaM0t0uBIYFwR2H4tG8dz9j7smhZqnU/NmRlXnxeFEvl9q1VWfhJgZmRtLMfixaAWvefTti6+ortF4YkBHmN4UHPrLFoSm8AMKWBYGOTx0bft46+8JwoBGUwA0opMDdKpXRllEJGIiFwaThtxyXmZplqUyJCOQpx4NAhyn4+ZRMRkp4DP2FDSgnDMGogREDaE+T6Al0pCQJw/r2kdarfMfIF3QBiNAAEZX7zjdfM1ftr+s+Vu1qQALOGYxnY/HuTOztMAhhxzPhhqRh5rqBYAZoZSV/g1DFH3v69FNWrZFScCMysOZF06aefb8evL/wY1b8BUjBU2cKxd1MSzAgC5g+vrBeUYgBUMSFm2LaghCcoDMFEYMBmA5gr9PUOLvY8IfpX11Up4ZJMpvyGozIEsBnHLAXg2hVkP0GkdX0agQgIiqyf7pZWX6+1CMwVBBE4c9K6fnnY21AKZqEIBdbMdSNWml2P8MsfpWjmi42C6xKq514bYHChCKUUzMvD3kbmpHWdCGxULXOJV85eBHhfyyQQVtcV7j6I2XaEoTSa9hnPdu9apneRehaWmLPCIMppzmYF9eZu8L0z9986Ye1r+gRAiMr13Lsc7Uz/ZsX0Kbcn4v/12/IvN+c8vyjSa48AAAAASUVORK5CYII=' },
    'snap' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADCUlEQVR4nFVTPYxUZRQ957vfzLw383YeA4VBCAlu1IKohEVclbAWmIwYG5NtbKUwNiodFTFGICTUJmZBLDAmS2M2UbKNGF3cMNmNELUwLpr4w+ACM7PM73vf912LgQCnveee3NxzDlVBEqp6rIirl/dvtH1FrPEgCAAWgAMAhXoXpLpJenjupR/IDzNV0JJQHdQnT3yweGZhOduTO9AYhQ8KQ8AHwBAgAcDACvSN6cVVHdTfJi+uWdXZ+PiRv+c+Pt+fIUbtqJAzDyVUy0UmZfLJ7QVz5ZeRDxrgXF9dEL12PZ5RYE519pDBT53pi418qt+52/r609lk7crZ6qkjL0fPPhHMmzNJ4a1XJwov7DLyzuxk8Y/G2erqV+9PGB20F34cTeHnzrRtdVySO5LMuGnH00y3HeDmx781lxobPoorvN0JYWm15/burUq6/QBdFLMkjs6TG22X2KI1XuChkuCfLy6EZxpL0ly+rn0f68L3d3MfgOAE61f/VP3kXTTX29p1MUQUQuOt9/f+Q4P/FpvKRgvNG/3ASDBhSRBo5Uab13rK9q9odTMMh1RDwHvQ4CFIpQCkZZhYAFV4BVwAVAFTMuPZRAljg8ewjwgEBXzAVitGAVgCijF/qyXhAxj04ZWxADkOys08KIJiJina1Apv515JQgEcSqOCAlh3Y879040INCgAQ15oDbOeD5iMrDm/M60crEb2xUrRfrazVp5OSpZBMd8aZYCCAESgNnNBvAJWyKVu5k82u8OPtlWj19PYHqxGiVegfC+K5271si/v9DMrhk6BzAWxtRTdgoU6r2FzxfBkszts5iG891iltKMoYgj8nvnw+a1+dvpmb5hYoj0IoWBhaim6Fru3LNf3DVZWfnOv3NnQlhhw7q9udu7ffv5UbI0FsZa50Bt5NdZgEKjlWGr1faVL2L1l2ZLzAx3UD1Nx5pvGaI9zSjGEU8UwAAroLlopmgJ8UFhLfe350ndHj6eHyfkBH6nzyuX9ra6vFK16eOF9jx0AiNfMUWqJ9DD1oM7/A46zi7GxXU3eAAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAE7klEQVR4nLVWS2xVVRRd+5xz73v3fUo/fLSgolZN0EBKMfGfaCEIDoxiQ6IxkTKQRBoaBjoxaaoDEkcCGoMJSqIDk1pwgCUIhmDCCGijxkLIA6WAFbCvtO9/z2c7uO+Vlj4HDtyje89de62z99ln70uoGnOfIOp30XNXCqgQ/pPFmGggfycXAQD39Qnq73d8ee2a0dN6y0jGdDCDiMDMIALAAEgAkgBjI0cGMIMhcHubOrvice9Luu/4mRon1dQ4s+6VvV/k9+0ZLDaNT7JmjkisY4SG4StCRTO4whxPCdKGISXBk1QTQmsz+T2vJrI93am3qe3YIeY+EUVwbf3qvZ/mjvR+Mh04Bw1tCMSAA2RCoXWhEuM3nVv1kCefeiyuPjs0VVnU7FGuYJG/pRmCq+EoFr7wPt6eLvW8k95AS48OK2bQ6GC4dffBQgsb3Fr5sOe/8WKrV9YSQQL47vhN8/RKX/14pqyXLVai+6VU/MBQTu/c3BA/MJQL3+xu9SpaIB4HfjozYYZOFip7DhZaOlfHtjJjRAFdyZHMnx3jEy5kIcTyJU68u+vDOPAogBzC8pby54PXwu1dTbHT5yo2m2P31sYG/9SvoWlOaXpv1wczWPl+d+X7E1N6PCvDkUzYsQJdSQFUiBnEHNWC1hYm34jJMAnjFoEhaOz3is1cNW5BStD5P0Lne0yHTxV0MgbSs7CFMhgEMAPMIKBCam6pMaRSUPwbZLkEFZQgpAH5kr76IRcyAweOMDwJGA0oX8GbhfU9VyvMGZsRYAb8OFPmErnrO3dz3DHpmMAvwwXLgYQvAesAJQmECHvh4lzsz8MFh4QHdlxfQEhgKue4OKoQKAFHhInxHENVw0a1+AGQIOTuwGarWNg6EdRMSkAEDEgGBOB7t0nrYeUsrPIAFOdi5gkwA6imkgGErj45AbAcpa2Wdq6zEVHfPSL3iHCPLwRh7tERAMPAIiWoQRDZ6lq95jVPwFV3Vvv4TDqmmBlyFsYTgHGO1ySValEShuf61RVgAD4RbmjrLlWMDQRh2jp0pn21LKZE1jBLippdzjBAhM1NgRcywyPgb2N5tGxsXDC5egK1F8vAwGRZ+4JQZsbdnqRvHmhMtic8WXKMvGW+y5O0//7GxAsNMZW1Do1K4Ph0aK5o6+JEc2piziFbAAlJ9PVEKXy9OfCfTfvyhnZYk/TliUda0iNFbUvO8aqELxd7giYNIy0ExkPLH/2VL3sUpepfz4ARpSBk5m1jU8Wx0PIST2LaMjQDT6R82dkQV4EgmjAOaUmQBPRemS6dK2qbEER1BGJMBK5F5hgIJFGmbOxz5ydyh2+VTKMkLFRiZsgskAKLlcT5knbrL0zkB7KlsMETZKoz5DZfjBUwUGhve/7s0oWiY+y6LScCktZGIteN5ZcvTuY3NMS9jY2+etBXUgAYN86dzIXm28mSLjjmtCKyHF28YondvUuk397mnwUGCooIzNf8/b2bkq/t2DsdFErQQQyCAcQEIQ5gaLoSDk2VQiGijDp2AANJKSglCQ5gIqBQgnMWXu+mZHbFk/5+IrCqjsxhzqzbBvC+3YPFpqs3reZZ1yYAQCTgqj2GEKXLGECjtsZYvkR6OzYlJnu6k9to6dFh5j6hiPod9/UJaus/xJfXXulc7c8b+vNuzyyrP/SPRUOf+t2M8//12/IPmQGoNtLhU8gAAAAASUVORK5CYII=' },
    'door' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAACtklEQVR4nHWTz2tcVRTHP+fe+968+ZVJrFhEaqmlNIUiNTESRapStENABaFxIbhI1y506SZ0E/8DF1JduNCdroT8QIkgEkxiCy5irInV1mqsk5kk8zIzb967x0WCncZ4l4fv+d7D55yvqCIiqOpkyPK3z3aSrJgLjeeQlybeuNDGDD/zjciVRBVxIqi2qiffe3v2w+nFzlBt29PpKogcaFcCAw/2WaqjM9e0UZ0QmV5zqpfyU+/cvjr1SfxcvJ3VX6+WwqfOONtq+X89VCHKGdb/8Pr+58329z+n50Guql4aM1yvjc4sdobj7ax+6oQzkxMPFTbT41FWOB1pcTDyxcFIyoPR77vHo7fGH86/OBK4eDOtzy52hrleG3X1LUrdFBERCQMjKzdb3PGvcOLoUWpbTYwYCvmAOMv47sePyQWCiEg3RepblFzoTCYCuj+qs/DYI3lmv/yK1bXbhM5RKecZf22McmTJ/J5WBEJnMpdl3EdLFbwKiAUMikXEsNUKaBswPeosQ9xB0sYId/9uUH3hSUaHBjHW4IKA6tmfOGYTPvhM6P3yPgPvIQwcKzd+I58P92ueeLeLzf6iXIE04/8NjBFa7YQL54f4c6PGL7c2CKylrxwxs36Bm+urVIoKPWfmrEV7TawV2jtt5r5eYuXGLULn6O/Lc/nNY0T9FtVeLeqS1FvVe1MlXWWnJbwx/jIbdxtYYykVQ7paoLmbIvsIVCFJvXUDFZqBQ9Wrqno99WhBvvhhHhNXiMzefrsd+PXODuOv7nFRrxo4dKBC03HuyMLFkdby8mr6/Mp6Wv90rt5+6cyObcZdFXNvtY+fdTK/pH5uKckKD7iBiyO5ec4dWRAAbVRPTl1pfDS9kDyx2dzH/N8soaoMlCxjT4fX3p3sn5D+6TU5LM7WHB7nzHuTOxDnfwAGPz5n+qSrnAAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAD3ElEQVR4nLWWTWxUVRTHf+fe9+ZNZ4qlLQW0CDFpQsCFlmqMJi4UiHFJgLDBGKAJIQZKYqJuzKRRDGIibRoTwICuTAw2xI3G4NKFEbEbA4EMKoWClO/OtPM+5t3jYtoC0pniwpPc5CX35fzO/55zz7nCtKkWjEi/q31vboZI+E8WqMjx8r99CYAWCkb6+51eXPfcmVPJtpFitQdFrH0016kCinZ3eadXP+9/ISt+/HXGp8zQtLh+w9Cx8uHBb6Zax266JEmVtKKKAFrH88xeRqQpEJ5oM37fptzt3dubd0rXyROqBVNTMPbamqHPSt/3DU00eZ4k1iBtLca8sCqwqasx5jJV8Hzh/Gjizo1WU0CrVfUHdz9W2f3Wgtel84ffPFXkzHC8Y2B4ss1aJpoCrHPwdWFx80vP5G1pUrF2bhWK4Fllopzour1Xy8WxJBVPkoHhyba1a4Idqox4sDk/UrzSM3bDxbmsmDBROlqs9Kz0Te9AwHenlJY8OH0QIgJRonQs9PjpQEVWLvfN78U4bV0oZuyGi0eKcc9qNuc9iESVmYUAzkGcwK1SlT27ttO9aglTYYIxZjZ2z1rC2LH/0yNMhWWSai0nqjDjDyLx6lWGCHgWnl7ZybGvvuXP0WsEmQyqioiQJAkfF3bR3prHaYrUSVRdwDSGUrnCxcvj/DV6jSC4B4jimJu3S/UrbNpM4+1G6JrKdB5AQwWqSnNzjhXLluAc9ymAOE7I5ReQ9RVtAJnniODsuVHe3LKeqTDBzibZkeLxbPvPHOq9QEuzR9XNTakLUFWCjM/Bw8MsX9qEqqF24II1yt0pw/6t19nwspKG1FVRF2CMIYxiBve9zePtPndKFbz7bpyq8NSTHfQe3MeBrX/j27nLqKECYwwi8M4Hn3Phj6sE2WC2iuI44sjB9zh3JY9TV8/N/DlI05Qg45PNBg+UqREQHLmgcRnNC7DWEsUJYRih08pEhDiKEDHUb4XzAgRVB+r45P3eh3JgjLC4YxGVSogR0yjJgYows1CoyRdHXPXZ+e5Rli/N4vTBSI0R7k6EUC3jWYu1Cjp7AVUEhUA9OD7Z3fXK6c5FpufSeBoGGbFhrHqrBIf2VLk8fh0j6ZwRihhyWcuCnHL9jlM/ECYj3LIOk+nuypyG45OeCKpjmaN7N+Y39Q1NNAFJHKu88eF4ecureS9NtW4jUwXfFz76Mna/nI0TEE0S9fduzN9a/WLmqAhad2SGkVOmlEccmWTzRjrbHx6Znki/00LBSFf/Cb247tLaNZltI8VqjxHEPGIrVIXU3T/0T9aGvvQ7uffT//Ns+QfF1gI0tFan5QAAAABJRU5ErkJggg==' },
    'led' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADSElEQVR4nE2TT2hcVRjFz3fvfW/63rzJzHTaNKlNMG2t2EhMoi1VQygadApK0TgFcaV0JyjUIsRFqoWG7lzahYkFN0pAEayJuKhN/8WGSRMLgg2lllbbYM0k8/+9d+/9XLS1nt2B34HDgUPMICIwc8HF4upAuYIkjDbSkVQqhShVI97akSITGwZItmyQNXRnzhFNRswgRQTm1fy2sUN/Tnw7U+szhhEELjXqMfq6M/LJHW3y7bHrYTLtUq0egy3z8N7aZV7Nv0M0fU0xF7zjH9waPzZRHtz+WK7MCnR29raGrrPxu7hKGS7+uqChFHVubxUdbT4dm7gzSMTjzIV9Cgv/7Jm6FPbXG7aUSQn1xstb3ON3dXN09F3vpV0ph41GYXi/8+FHJ+pvvRI4V2807fmaWZmeC/tHFtb2qNIagliD4Aqambmlf1n4234/+WlyqOeSiq6fBoGwtbdb7Px6NPXCayPVv5ZuGvieiGNQaU0HylfCaGPxyOaUeKIzJZKtAzT01Ipau/IdlL8ZIEJ16SIe7+kSBwqvO3Onv6SVpo9YV+AnhBFQkrS23JbzxbN9G1V7e04gXAZJDyQECIBwA9jGMlpzKXqmZ6Pa1tki4tgySJIKQwNvnUMXFpd18WIl3tEvVOXwYfaTp6gZVkEk4coQIj2ImfOnzPQ3ixHWZen5Pk+FoYEAAGaGcAkbOnJi6bdF897RnxrlTYdY+F1Aoh386Ps4euJG88epH+Lclk1CehKWGQCgcF9sgTDSaFmfppOffRG9uPOu8+aBVx1jDIrz8+bIxyebQTpDUWxgDT+IQUmJhw4AM0Ceh/XJKsnWIUgQcsEceb5DgABg/mOlBKtIW8kMkHjQxEIlXHw1dS36/Y9hYy1w807NQngAG4DuscxApK0U2TSqjgJbzawEGAQIRTgzX9XKrCFwyzh7uayNAQsJKHGPdRQ4m0ZVoTc3m9/dKBav6r2lCpeEYDADt1csj3xeaQJArBmxBnSN2Vpi35PZ/O7Ez+jNzSqiyQY38geJMT41F/ZrzQQC+P4eYIAIICKAGUoR79uVODMylj5INNmgh3c+4qJ4YaBUNUlXsTFG0v/HldJwpElmA1nD08+dI/okYgb9C8QrmmIDHreDAAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFQklEQVR4nKVWa2wUVRg93713Zmdnd1tYIICNKFhAG0ygFRHxAULFB1EQURKVhxjEH6T4iP7wR7MYFIwxCIiQiMbExCg0GKORh8QXgggFogRQqtBCKSpQ2u7O7s7MvZ8/tgstFKLxJJPMzD3fOXe+fJNzCZ1grhVEKVO4nxEH8oQecRpA3x7eR5hoffpiLQIArq0VlEoZbpx008Hdwdz9v4dVxoCIwMydHAZsi+DYCu2ZANRpX+QIAR55naqvGG29T9d8taeoSUU3bqietvK99NoVdV7vP1oCXylJRAVhKQnZtoAfmVZuPzfvRnXL1E+9qKtIm4I7EZD3NQ+5yrJrprutC5+MP03lWzcy1wpFlDLcPLly5dsda2pWpR0Ybh86OCFPnMpwGBp2HJskAVk/bY42ngh37rZteOdyMpEUEduCHwTI5jQPH1wqjjRlcjUrOxyA1nDz5Eai1F7BDDq405+3vC6TtC0KKAzE/JnXOxtXT4zHbUvkMh7a2tOofvA++95pi+yzcipmPjnHIUhqO3cO2md69YWq6OrFt8Zs0kIqCpbXZZIHd/rzmEEKmBHb13Cyqvm08W0LQpXY9PLru3Mfr57kjhuTVAePkH5nzTK3+qYSBX0EgAbkwzj04lzz7EtveAd+/sGMqxygZr/4rWcAciMQzaeNv6/Br6rAjJgC8sSM4gUpCcJRmPrUpsyAAUnx3TefxYfGN4mO+nVgNgAYAHBD2Z3i840r4ndPmZ++Y9qGtNu7hJyoBa0NinpAnlTXQWMG2lvzDKWAMIOly1Y7Q/vsE60/rkAkUdaFSWg7vg0J6WLV8iXumNvu6Uh7AaNNwymxQCTOM9UFcYZtKdz/QLmldYgd+xN6/NgKFRxbDDuaLOyczflCK9oP2ZbvMbxyjhhZOVqa9CEMHjZQbN9xImg+6aHooQCABGAMI2JJqpl9QyTv+zjc+GvWUSGx3woIVfi8bhAwOg+Jc4jHSql63NVqwpQR6vjR1rCpsYNF54+igMLGpBTo8Hwe98gXaRiDeEmE2jzJfWKDiDP1ILsE4PC8ODiEtBLwuT9OnznJz6f2ZLH0AKJRCcu1SGsuMrt0loBEwqJk0qX0mTP8Ud0mX5XPgdY+oL0uzBBB9i+4wx7D17uOh3t37wlL+pVQImGRklScg0sNgEKr8kGIeJ8+tOSVpbkvv8mHpTe/CWOXAcIGhAUjeqG04gU05arN/GcWeUpZxFyovbSRV4DtROihGY9nPthw2HeHzAL3vgvcazycQY+i/lhS3z5harql5ZSJRB0YY3rUuKxBYaokcmnwb9uXGZHbBSNLwSoJxX/iVH2Km461GNd16HLiQJcx7QmGGSQlXDdKZuATAK4CGDAERGJbIOyzMObipvwHAwBgY6AsBdH+CRLZfgAYcEM40qOC9v8w0IbhxIk+3JLzt+56N8jmfBABthLI6RgcR9IVulM0iDARmOjSrTADlkU4cCSvZy3sF71lRFTm8gbpjOHZr53yAO5Mpe51F/QirID1mVHlE+rL+oqqpj91zo2S1Lq7STQmaNueTPjLHzmtNRCEDFsStO7+g0sJeFk2g/pLe1S5XQ+szygiMDfb6xZNjz1cs7I9mskiiEa6TBcDSgCbf/J8hCiELAGxmCAhCuvojM9MFsZoWIumx85WjLXXEYFVZ2Tu5YbqBQCvfavO633ibx0wume+YwtQ5MJzEHZbBoFxbX9pFSIztoDKNu+9EJm1tYLKUxu5cdLxiZX23H0NYRVz99C/HIocIvCo8mLoby2EPqXM+eJ/f2y5HHo+tvwDzx+Ss9oCQ6gAAAAASUVORK5CYII=' },
    'palette' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADQElEQVR4nHXTy2tcVRwH8O/vnHPvzbwSZ9JOJGkVMl0kaYKlITGUlsYuJAlFXFhc13YlPqquYoViQaMigvhCiPgAEUTEGqQxCopoaSNJU+uiDIk1EmpGk96MmfuYe885PxfZ6v/w+RAziAjMfM7FwqXDfsPkXMXGGElSAQBgNCCl4USTLOZlgMFDPxI9nzCDFBGYo7HK1FNz7138uXlQayYpCZaBJGUwA65DUBLQhqEk8fjQ3CJHY6eIZlcU84nMi0+vTb/wcXA0jNmXgoWpW4YHlDsUuQ6wtm4YAQMFAQLxQlUfZcI084kJhaXNkdn55mAYs1/IgaIQfOZkq3tsqOCWWh0RxCAhjLm09E/66qdBorVFGMO/ON8cfHZpc0T4deS1ASmwIAbNvFzO9fd3ZL+cz6q790hxsybpmXekau/am/l6qpjvKCkhtCVrQX4deeEqYaQA9Lbl1x4rtlS3Wp3T5xm/rBl07iaUsyHWe47jpbvewlfhffLdJ3IZZgEC4CphBAgUxMw9vY7o3lfwVj5x8OfgHeiqeRh4lHDmbaDUWULvPbvwxlwOFhlnbDSj/IZlpUDK84Agtjg84Klrf0jkEsKdTUZZADO3LMoqh9pn76P27QyiW7fxUyWPI32hqq42U08BAgAYgJAEzxJe2YowUQG+yDPKkhClKfp6KnjoUC+EcpCkDCkJtEMEwmgg4xIWllO9f1eK3fe2wv1wP/qeqyAKE3R1lnH/kf4kjTcaDx4/xn17Qlz7zRglAA1AaA1uzQq6ejW2txthevpggusfbGDjBx9KEbROoQ1TYEpitD+kvaXYfP5NkBYLkpoxWCTaSmsB6RKefNOPHujeMid/rWL7Qg0xXCz/7uPC3BVnYjjKjpS/s2engzCOLQQBibZSFdvQEBJspOC/69ZOTNYa5x5p8z46m3f9bSUAB3lv3S6v3kgffj1p3lzXFhnBJMDFNjQUDrRfHh+OFharejSK2Y9ii8fPb0b58lZzoNsRjgJurGr715phtADkCs66VBwf9r7HgfbLBAAcjVWmJus7mQxIyp1IUZPBDG5xiVo8gjWAlODxIW9xcqrtFGVmV+j/OsNIUgqABLQBwP/d+V/zLqapO+83ugAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFvElEQVR4nLVWa4xV1RX+1t7ncc+9M/feYYYOccAZcJSHNA2MpFWgCSJFm6AgoWlTTatoRmsIttGGR83N8FBCYsvTdIhViMoPx3Fiq1E6NqAIVgszijiFMog4gMod4b7vPeeevZc/ztxhMGpiUneyk3POPuf7stb61voOYWgxJwRRmw6ul1QBLuE7LZuJOnJfxSIA4ERCUFub5tM3Xdf3n/Jdvf1+CzOICMyMbyWqvEMEntZsHJ4yw3yaGl8/VMGkChv3z1u09alc++bOQs2ZpCqPxBUE0NAOwgX00B4mAmPsaGkuXxy+uOzuqlZq7u5iTogggrPzp2/dnn11+daMIySVHRsCDAgRgBdcsFfSgGKAA0YZEgiHQJIAXwW5KLrQWrG5eVm0uOyB6luoYU+PwQzq6/SWburMj5ISmbADqRRgSEK+qNkvMsY3mfLG6RHj2kZTmCZw6lPF+3pKfs//PAVmRKOClAIiIchCCeVNnflRc6fbS5nRawBLIr3951rODmovZJNQCpASSKcUX3uVJde1xu15M8Lm+ZQkXxMGM8DN1zPWtzL6Pvb81e0p97W3cuWqmCCtgZBN4uyg9nr7vZYpWBIRgEvMoEoxpQQyac1LF0btd3Y1VMVrotYv1kna1MUwHYUDRxV+vBz42QqN3g/LxksbaiLbVo52igUGKFDNJTyXjJGKMASQSmv+5fwq68k1o52HtgCPP68xto7Q8SeGbQAP/Zbw9lEPLx+twbGJv0JX+zvoaj1uE+rwwGPJYrxGXKay4TsioOQxxtQZYsfDtc6qdsZfXgCuGSOQVozdewkyChx8l3HkjI0pK1bih/f/GsfnrsHCLY343YKQPX9WxMxkNcsRHMMRSAEUMpr/eG/cGsyb9NxLwJsTImgyJO74Ioc/7FR4rYfw3gmNC56FuvorUMwCDePj2Hcyio69jPX3xu3X/533Rsp3mMtXgBUWdPvssPm3NzTuFCHMdCw0CImN8TBYMLoPAVnPgF3O4Ny2dfBOvI/PdvwZdOoInj3gYOoE07i6yZKex6hEIQCABOArRl2NpFExQ/SdAP6pPSSVBvsau4ouJAGxCCChQbYD96NjOLn6QWT3d8OpDuP4gIbrS0waZwj2mCtNeVlFBAFMgFSEQ2UfCz5NYYFfxK5MCY4Cyjooluu6gGnjqsnXoKAJzBq+AlgHzXmZcIDgQApCKqs5V1A8qdEka79GelEtnGVNmPpKEqe2fQJBhLLvo25UHGtX3sNhW6qPBpLGqvVPo3GCAdvSGEgqhgGqlGGYz5RALq14/weuf+sMhllrYtLvx6PaINT/5grEWmJAiZHO5nD/3Ytx8K0DxQW3zMn8IG54P519A2ZPzmHwoq8+OOkp0xZQ6isEGoDpEG14NuNeN5lx88Qy3n/mPJw6A+mDKeSP5yFCApIEzicvYML4sWLSxB9JYcYoItN48HYDG3dn3VJBsym/RkVaA5GwwHt9rtrwzEV3d0Ji3L9OY8/iPhxb1Q+dLYMko7amGjt3/x1FZYdWrNsefePgYXP1oiPo+xj+E51przomyVdf0wcVqVbFBD3SnirW1xrUvTlmrf1rCs+dFTjnCuihcQAmtG18CrfNtGjtXT7SeVILV35WMC0QBfN2JIHNRGCiSweOQ7R0bbLwZm/JX9MaDz18hxTvHiP8dyCIdNxowsypUUQsj7d3uW7iyYsuwLAsgubAhAI8mw2gIz+tec7hhjrR8snnqhQOkVQMVEcF7fpH1uvYmy/fNits/PwnIWPWREuCgIGkrx/d6aoX9xXKZ86VdSQmSBCBABRd1lfWS2tas3UY6Mh/s+EgGH5lBeRzmqFGJHQox3aEKGxR0B/4RsNJCKK2Hu6fdx/Al1mmhyDlTliAKEgPcMk+lQby7tAzMJrqK5YZuY8a9vQwJ4RB1KY5kRDU3NbFp28amDvd+j+Yfndg+tSmhz/+vn5bvgSaINbeEirOjgAAAABJRU5ErkJggg==' },
    'serial' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC10lEQVR4nI2TS2xMURjH/985595r5s50OqmUREJEBBvBeDQIFh4T8UrUShdExWNJQghBCKsmSMRCqSjxSixEmmok9UqDqMcOSRGxIWlnWnNncu8953wWg7Zh4dufX77vf35/YgYRgZmPuHjbszgsG19bNsZIwoiR0nCkSWZTMkBu4VOiYxEzSBGBuZifcnLP/Uv3esLZQ4FF2hckiCCkAEAAuEphQElgZa6rlyv5bUSdfYp5U+LU3q+tx9uCJe4YKi7JJZz7PWUdh5ZRHmTA/oL8IkDxi3e1S5nQyrxptcKb/oaO52HOaFvoapmQXrDIV1duFKLdLUPlLTu2eo7rkbUWDMARAoVi0ba1dxQ6X4S5g2/6G1RhEKk4ZnI8orG1QsAj1NcKIZVDK5cvdfxUirQ2ADNcV+Hjpy/28rWOONagwiBSylXCKEkoB4w1+7+VVjQknVtdpTgMDdY3bg9geWSWICUBmQAR4CphhDF/DsTEcUpMm+SI8XWSrOXRL/8xxoCUVIA2DD8t6Nrhen/sDI9yk6XK7yuVrlw9k/TTf5/QvPto+TdEGQ0IQQjLlrtfVfTaOul0vw51FEXofPBYu54LaxkAQwqBgf4iEw0rogCACNAMNJ34Hiy4M6SevKroMUmi86cvhNVvHGmUAvnZYYCUVUsEA8ebs4mN+bTTcrkYtt79EU6dOV0AAr/jEETQWuPz135btROsDFsZa4ZfI2jXhoyXnuxi+5qkd6Ob45vt5/xMpoa01mBmeK6Ddx/6zOoNOwNmINJWqpoUSgmP+MeANYcuDJSb1tW4J9qGwiCo2MbNuwKAUF2gWhpYzQzBjgJnMygpzKp7tmpepffle73sbHuxcPb6YAQGyCP62PfNgnnYZABg4mTazebnew8xq+6ZIrpd4Uq+mRgXu3rDOVEMIgFYCxC5owNkQCni/Fz30YGTmWai2xUaVefensWFkvFd9f91/gk2r2ylMaHclwAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAEcklEQVR4nLWWW2wUVRjH/9+ZMzOd7m5vQBFKJDGVh/oCLITghcjdGjFBaGIIqNBESEgF75EHN6tREoypWH2oCaKi8QE2xSgggQeiRoJS9oFLkGwTS21tqG51u7M71/P50IsspRU0nmQyk3P5/853vvN93xBGGnNCECXV8HdTFHAJt9VMJjqYv1GLAIATCUHJpOLuFQsu/ehvTmeCOBjEtyBLBGYGEYHn1cvOhoX6fpp98uyoJo3SOLNybduH+fZ3U4Xqvt+V7/gMXRIIgLoFEoExa5qm71hXPtiyJbqV6k90MCfEsAW9q+e3vT90bGdbzoIgn6GobqoU1waVIgIMCSLSoGkETAAjIuQKgQoDpe9tqSi2bI81Ut3xc5IZdCnlNb+TsmuERjldQuzeOsXa0Bgzzl50w+bdA4XBvGLftTm0CwARxlMIYIZVU6ERpN96yK5ZPt9sZkZaAk2RdKYv3p9Vfugran6k0tjxRLWZz4ZoXBaRe/5ka9Oun/OPrl1uLHlgkfS8AJoQJfKKGbqu4aMDKe9Kpkv9mjW9dMaLN6ApIgGXmEecHTJqa4QAAUVHIeoJzJiqEwIH9y2Oy+dbtphF14eUshSgFExdw6lvzgQXLlyGFS0b0XRpbGaoACsmqL0j5z20oFzeu8iSvT0+72ofcPSqKnqr9QOntW2/O5G/CUDBcTgSKyc/UGP9YwBmQGqEXEHxsmf77LlzTK2rx1eDeaUsU5BddMFcnPQ+CSEgRGn4lBwmAfB98N2zdLE0Xibjc0yN1XWD/6KNWSAIcDzGPXfp2onWGdHaOp3gMDYmrxU+/3rIq5lSRlLTJwy+0SMKw6BkN38DBODkFG9aHdNrZ0jq6/ZxR63EM+urzc9SPe6Lr71qvfTc05M6eU3TVvurIyc9KxobD2AGNINwKl0MX9hQiZm1EignHP/BDqCX0fdnzgZvt0lMdk27r/6iDFMHM48HhAqIRAQdO13wn3x9oLBpTcw4nS4Gbx74wy2vjtCXR0/5Xxw66k8WaEZlBZllJrneTQDDOwEsS9Anh3Pe4e9sP5cN2YgKksSIVURJr6mc1NWu5zOzKumTN04KAsZ7r0yzHm+MGp0X3fCpN4ZTRbGQ59Au8D9aYOol42MAqQH5oZC3PVZlbN9YZeazIVY9GJF7Bm89VXz8acr76UpXIKQ5gQUKmPYfU8X585dh6WXXA0wmAisFLh9JFavilrx/oSV7en11u6kiWhEhP1BMBAZMlsBBe1790s6ZU0S8Z0A5Q0VFD7/cby+Za8kLXV54tT9Q0Yggu+hAqQIPS90cYxgaHJfUndOFMa/e6AQO2oII3LDY2LdzfSQbBKwHIYXM4CPf2l5/NlCxCIEVWNMEG4bOhiFH3uOfokNhGLK+c10k27DY2EcEliMl8xxnVm4DuH1vqlDd+5vyLUuAGXC86/c4ca4jMGZPHy2ZkW1Ud/wcc0JIoqTiREJQfbKDu1f0LJ9vbE5ngvhoIR+tFRMK37Tonxgu+pRUY4v/r9+WvwAHeH0R3xZHBgAAAABJRU5ErkJggg==' },
    'unique' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADEElEQVR4nHXTTWhcVRwF8HPuve++mTczji+1mcWUjm0QKSKUxtRalCoITkUXErIqotCFWKjSomBXpYJGEF10oQgVRRBBcFNQQxB0IRJrJ1QUqy3VYqVNP5Ih6WRm3nv33n8X48qP9TmLszg/ioAkROSoRee7B7s9X7FGvPdCbQwAwDsHrSm5o06reh2Tu78lj+UioCEhMmhPzB6af//LH7IdzglBACSc85AgiKwBRAABjKHsnZpflEF7Pzl3wYjMlF8//NeJ1z5e39MfSFcpIUiGrJBmq6FqSYm/di56lVggCEKgdM65PUKcEJl5XOHM8q65U9lkf+C7aQ1MymS9QiAAB2c22bcObS2BGvVklKU1sD/w3blT2STOLO9S3VVUCwcqQ7oAAoQLAZWxOp98gPahbWtRa6KhhpkDSbgw6hYO7K6iqqxRngQAItIEGXBzqR8eub9p7m7mqlZew769TTtYLoIEh0gTAEEC1iivvAdJImQFVq5nElDF9PQO+8Zz1ZJ3PQzXA55/wsXPPnNfHMcpVm4UEvo5SMB70GgDFM6htbmhDu7bHD82KdE9mzLl8htwrWNgvBEbz7/MDw675Pent4b501uKdz+9mhfuOrQBFKAhQVBLStzSTFRrXBRVDh8IxuNg3EAQC2CI5phX995V0WNphSEIAMB452FthNOLF/30gUu9OycaeubRZvTCU650x/mXGMQiy4fyzheN/MOTl/Off/nJI8+we6pqvAOM1hARgSpb3J5QXb22JG8evzRcXZ+S9150CaSH4yfH81deXejbFCqtR1wbxiICaA1RuQtaBAAEhRcYE6E6btVnX/3p/rhWCVlI8dHnl/M4hSqXYrgAiAhEgNwFrdI6epGBBCdi1GiNNQbLV1bC1z8q9/1vFXf27BVfKkXwIcCoUTcykLSOnsH2DQvtnYNO55x7uHtTukoJ+gSBgLc/WcrqtyWUPENvUBL5+8pJWaftnfE32L5hgQAgg/bE7JHVf2MqAoIIrNX/wBQvHpmt72d57gL/n7OmHmmGd4DW/j853wIVwqbIMzp0KQAAAABJRU5ErkJggg==', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAE4UlEQVR4nLVWW2xUVRRd+5x7zu10+pp2bIEiUKgEC4ZHBW3wEQQFFIyKGIwmKHwQYxA+TPgxafohP/60KSpo0BgSTWgaNBh5GuMTja2NhgCRWvoAyqsPhunM3HvnnO1HOy19iX54kpPc5O671t5rn33WJQwt5mpBVGMHnzfmAB7hPy2XiRriY7EIALi6WlBNjeWOVfef+TV4taU1XckMIgIzY5iIAEAQ2PIwbCaGCLy43GmuWKo+ppknmzKYlGHj1sefrf8ovq+uMRG5eN0Et+EOgxtrwdbCUQrMNkM59J4x/S6pdmzI7tu+JWcblZ84xFwtBiu4tHpJ/bu3juyoj4WEpCDkQowVwKQNIoURyg6F0dXVabWriZlHxSQ9WGtY1W3PS25/PXctlR77TTCDzpzyt9Y2DhRKiSAcgmQG3b6lEJSM+XhhzTz9zpvLsr0EiDA6hhkUDkFKiaC2caDwzCl/KzNIABvDLa1+5aUb1s9ySRgzvn3GGqicAjyzXKmnlvSosrmzZMrzQDRaRmOALJfEpRvWb2n1K4GNYQF4wxlMdDakFEjEPX5oWZlTda/nKHRj05pZjh9nlmLigzaC59E4rccREGCtwktrS7QWffATSby4Uuv8kigZkx5Xxdg1KYEUAtoh9PXFuHjaVPHkA1B+0kMqcHBf2U35WNVsFb8Wt9oZrHIynjEENBRsEYsNcF/M8t0z7xF1u5aEpuR0k+elIOwAgvh1vLWlxF30YKXT288c60+wNQaOI8ZV5IxgE4xJI94bsMyLYMXDFc7mdSX66SpWEdVG8f4eOMVrQDoK/3IDFpack9+/Pz33mz9mBAeO9vjHvruQvnnlKqs8CRJ6NAEJAoxBpKiA3nilQj/3iNYLZySlKy4ilUzhVtKDU7waYs4uQAJSFSHZvgdSdmL9IketryxQv7883x75ZYH/6Vd/+efOX0amu8MSsbXIzcnB4ooSObfUCFf1I/CSCIwEgUG6GJAAGEBWKYiAwEgkEz5g+7GwzBdPLI+qaLSQ2FrOTLkzCM4QSqG9q5M3bWtPlJbPFJvXzdHPr3DVolkxyckrSHQfhKMKgawpMG21cKRAuCAPF29E+OCX8D872u03NTcbQUlWbsjJ3FfDPWBmuFojKwq6cbWLd9d1pGoPFHqPLpst335tfmhB8Vnpte8BEUE6QA/P4931Qerw12eDzrbLVrgWuTmaSISR8kamdaTJQyRpCyilkVVEZG0cRw7/kO7uXZr4+b3pucLvQJodhPPyUVObSn2w72QqOxoS+UWaLAPWMsiOvgomnANmRtpYWBbIn5pPp0+3mW9Pu+lQyIErAnRcL7SNx/70w8XZQjoaacOwlieCmnzQhqjALJBOxfHhF70+ywjcsMbnP3HQ032NHenAWvuPCGLQicBEmDAFYxnZOYqO/9gRnL8Sth5H8cnhi76jLU2SNEbwXBZAw8Dict1cGhU65bGVcpxeUMpB7Oo1Pt5MQdOFaaal6bzJDrvjZJESSHlsS6NCLy7XzUDDgCACV1Tp/Ts3hHuNgRpIwmQyyGzLYDcM7D3Y6lXvbU0oHTAgeWzcQBLGGKidG8K9FVV6PxH4X1rmoOmm0wbGWLiuwqCb3dkyHaIay9XVgsprDnHHqq6VS/Tkpi+GoO5o+icGTZ9q7PDH/9dvy9+XXplL8VbPvAAAAABJRU5ErkJggg==' },
    'translate' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADP0lEQVR4nFXTz29UVRjG8ec599x7585MZ9pCoCIkLSxcNGqE0KRYbXWhhahEmi5MiEZhpwkGV2gNGgOExI2JSzDx14LEDW2AagIagzUK2BZqKkIRTVFEyrR05t65d845r4shJj7/wvP5UgQkISL7A0xP9N1dtIVQK2sIAoA1AAB4npXM0GsrejVs2nKWfDcTATUJkcXBDYff+PKjsYnskdQIcW8k4GtCBAAEEEBrytbNX/0kyeAucnxOiwxHh/bOHxk5Wnvc97FYjEhF0jgBAblzxwoUoTwQgDhHufCr6RfiiMjwNsrsU09s2nnreGtB45N3VhV8gktVJ7mQKOYVT59LGrsP/5NYAQhAK0hl2cljD4f62w9bt6u0YopJHdj1XCm8f62vygWPQyN/106fr5u2lZpDA8Wguyv04hRCRVghlSYbBqwsoahCX1lPAUkqcJr4ejIxtytWxn9MjIkF1VqKNM3gkgz1eoY0a4BUIIFAK6uNBQWAQEACH49Xs44Vmt9fis3Fy1W7sXed19mpuJClLEWKadrA5V9uOKAEa0ENACJAKVKUqgMBHHtvdeGLM5XGD4tD9ubVXu/p4Sz/fOiQZoKWYg4nTowlU98ds2EYQDc/BkbPxo3tAwX/07dX5cU2sO+1B8Kxq33Y8eoo3n/pOg+MdWF+QWP9mgj792wN56ZHk7vLMXScAi2R4ucnl7OZa5ktFhTjOMP6LvCZF+J8a4vms5uXsPa+Kzg+sRpnZtchiWMo1eSiPa/pROWI2d8zZyzFpRmWTZ39sYcX+//E9B9lnJpcifO/lRH4RPNQwFMUlRnnNaUBUUgUC2SQI1sKHrWfY4gKbt2OceNmipcfncGKaAH081AQZMZ6uq2Mqq8hzogoEsYJw1yAuWt/OSRXsvbu14PBnuvYvaeKmeky2h/sxM8XJ7LlWuI61nRUKTIcHdw7f/LAZ7WBOJGKUkKAdMZIEPnY0vOQt5SEyAwRBQKNmkxNXSqN7Gz55q0PercRACQZ3HBo39LRU+fSjcYIQYAknBNUazVRbBpxDvA8D8NPtk++ebD0CqPxOf4v5wsTfZWqLQRarLVCQCMMg3ttWlhHlS+xhu6e/3L+FyRDmSFZ0FoWAAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAFH0lEQVR4nLVWfWhVdRh+3t/5ul+72zS/2kxbw0qUmjMqgrRUrFREbAqZitPMyvlBqCDIZYplkOA0Cw2yMvxgzKlhbWhFq6zQqRj6l2l+rq7ueufdPefee87v9/bH3XVzH0J/9MKBl5fD+5z363kOocOYI4KoWmX9ihCQJvwns5iotr17LgIAjkQEVVcrvjxx7PkT7oLTF7xyZhARmBn3Bcq9QwQuK9WbRz5l7KJhx07mclIOjS9MmrHts/Yd2w7YhTdiymXuPSEzIFUvQGAUD9CM5TMDt6sqQ29S6dF65ojIVnB98pht2xPfrtye8EuXXSjV+dWcqzPrk0nICwpSqku8w5w0lJJs1FSFnap38l6mosZTOjPofF1mYc2BZH+ZUvGyUZY5c1zQyCU2dJAnASmZLZPQdCYtjxxPuqGgoO5VBv3QbAfulrpkvwljrIXMOK0DFcGzf94ov3xdpstGmkbDh4NDA4cYBAlAMW7FJPcPCyJLAMxY/Towd33U3tOQyIRCgrq2S0rAZ5G4fktlTl/IlI9ERVAAaSIB8myFigkhY+CDOt1sceGmFY6fceTQyX+1baltS0tPIRr1AAIWTQmbCoQ+xgRmUHY50iS6TAnMAHuArhEMk7D3ezuTSine/13STTuMgEVgBWQ87tH/vkx0DxAA0yC0tko+1NTuvjW/0HepxVMnzqdkwK+BICCEBt0wYOg69C6PpvVIB71HRAFBP6HpbEpeveKq23HJ0VZPNZ5Mu+PKDc1zknCSNrzY3xxrI0ACoI7y/T6EC8LIBnsBYAaYssN678t4akSpqY14zBJTUzA+2t+SXjFnvDWw7CV6ukCKrZ84fkMHMQPMDNPQ0HDsV6/uYGPGCoR6AeBsa0gACVvxsEG6eGNanjGvsp/xR1NcrTMHOldDa3nP/gS5kkUo3/AZhgJRtq2ptIuNG6dZ/fsV4NOd+1jXCzoBuOOAms44ctWcAhQWavTVpkEBpBh8XWLkQ644WL8ouHWvjZVrd6O4yI8Ns89h8+ESnLsWQjjAaGtNYsHc57Fs8Wvmzh377jKBDgCeBMygoG+O2+689VF7/it5pucxhACE0JFO2BgdTgnijNB9hVg1M4pZ4zxsODQYxYMJpk4wDB1CENIZNzuT7i1iBQSDgnY3JDK7GxIZIgKDYRgm3FgLb/nYDvQbolteRuH0xSBovMLeZc0o6u9g5RejcPg3HwRlWa/PLWIGwiFBnQdEMHQgHhfwmYSUKzB4gIPKF68i7ui4GPWj7vdBOHUpH7rmgLnncfRY0+5MKRWgFECsEE8aWDHlCkYPs1G6dBxa2yxAMMaW3kEmLcHIcvd9AXo3hmFZMDiN7Q0hTH8mhl2Lf8KZS2GUDHLw3KjbmPV+CaIxF0G/1R3AYiIw9UEtzAzh8+NIwy/eB5umWMdPTsW+8zZWT7+IabNtoN3A50eHo/jRAFYufBbHfvjaIyUhBBiwWAdqk2WlLzQXPSDKr/wjUwE/abLzECGlRLAgj+rqG9yCwnx7TeWrZntKoKnlcWhRhlKEokck1j1J+PHnw967azY7D5fkh58o0ZqB2uQ9grN82x2/0Mj1W904igEShERbO4MB0rIKxqC7nKcYgO0pCoXNmuX5TtXboZzgRARR9Sm+MGkJwDtq6uzCazel21OKGf5gXofXKXOEnOgxhg7XzaUzfLGqeYElVNR4ijkidKJqxZGIoNLqer488eqEMeZ/Ev2c3Sv6R7OiT9Wd2vt//bb8CwH5h9iOk6B8AAAAAElFTkSuQmCC' },
    'report' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAC8ElEQVR4nG2TS2jcZRTFf/f7vnkkk2YySUt8VKUNqBUkrVOwxJDGhTa+aGiNiiAIXQpKqV3oItJFKwiCUEqlpFVB3Yi405iFCIYy1DSGVDCEjsYXTbHpPPKfx39m/t91MYWm1bu7B+65h3M4ooqIoKrvxLl4frhQjFLxpImctCQMQwBswoEmtFH3NtNjK2SHZkWONVQRJ4JqbWzg3cMzZ6fnwke8txL5FvWGwcU7EKDZDInbdWKxGEa8ju2emdfa2CGR6bxTneg4cfivqeOfV/ZW15sFahVIdsvZ9/d3Pri1aVuRUqp36ctHpivBlT88yU3MLbf2KkypTjztWFjbMz0XZqtBs7D1nrQ58sbR5B39d5qXhi7HCH8ALHTu4LOp46krq1f9qQ8/rl9aXCl8O+eyby+s7XGFEl3eG5FqWcaffTHmJZU4Onmaczu2sSWzHYBypcTizyfdgf2P8+orE/7N1ydrXrulUKLLxZ2JREABa4Xl/O8Urv/NSj5gKWwBEHeWarnC0vJv3L35IRS5gZvIRdGNDRDAE+e18RTP7+uhFkQAdHQYLlwSZvIJNk4UIW4j4BVSSeG9UyU++CoiitoExhiaQZXxg8rtcwuBMYZ6PeTAC08xMrSLRqMJIjhrWFpeYfWf69zU+z8Eqopzjp8WlwgqVVqttgfdm7pYvXqN/v7NbbM2PrX2JqSqGCMYYzBGEDFYazl/YZFcbgFnLbqBwFrUNVreqraVOee4Vlpn2313MfzoIPVGE2ctl3/9ExpNykEVaw0CqEKj5a3LpAliDlVEg2BdR4dHOPPRl3w3O496j6oy+PAD3D9wL6MjuwnDsipozKGZNIFjZ1/uiWzt4o+/9I6e+eTrgkumzXP7hiTy7Za144oQgVKxqCdPfxp29mV6n8y679nZlxMALY4NnDhWPPdNLty1VigR+f/G1TYJtvR288xjnfNvTaYPSc90Xm6vc+gTqYQxHnvrbSsCvDcuHlYY7JkV+aKhivwLmgRb636TmdgAAAAASUVORK5CYII=', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAEQUlEQVR4nLWWf2hVZRjHP8/7nnPv2bl3c/4YNZWMWoQmyFxR/xRZSr9AsBSSwH5YGIU/kKgUYtgfGUSmSUIkKWL4x5xFv0PJSGRIruEfSdFExM1QNza3u7t77znnffrjbprbnbU/euDAgfd5v9/ned7veb9HGAnVZiOyxZXfV2ShKEwq0irSkhuLJQDa3Gxkyxan5xbfffqX6PmOzrhJFRFBVRHPWlST6+BEhDgBEdXR3MYGr33ePf4emXPk5CimjLJp55JlOz/NfbyjNT+163ISgZR3oRRzBcUGo72W64qL+KEn1vNQVVBldp311z8V9q19IbtGGg5/rtpsyh10P7Jw50eD363fOVBlLFGmypgkcSRJQrGQ6Jsbnk4/8eCtfqHkEMC38Of5Yfda897h3NCg+ilfUp7P4HDsXIK/Y23N8NpXqx+TWT/86qkip1tLq7e3Dk2zloFMaGw+VyQIA6bVVkvt9DnyxrO3hFNy+3BkEMBFg9y/4FEOty1Jjh45HInvc/Fij9bUhHYo76LtrUPTHl6YXq1KhwcrMh2dF5q6e1wpDIwpFmNmzrxJPtuzPay/uc5GWMKgHeJ6jK0BUWw8BHGWrW+/VFXatKZKRPTldW/ljx07kYTZwHT3uFJHZ6lpHisyHhRFFVFFrLEUei/r61s3B30DRe/JVS9SW1vN/Lm3cV/jA8SxA8Ba4WxXHz8df0X6+3M898xSee+dTUHTvY/nqghRTUQVgaJ4lQRnrXD2XDeXLlyiFCtffd/Goa+PX5djjJDNBAwMDHDmbBdRFIEx47AqEqhCOp3CpH1m1HpMn5JBRMoCGhX3iDajkk8qnSqvV4iKBAJEsZKpUn5+36cmTIhj+CeGc5DJGhZvgFxeKxV/gw4Aa2C4AOt2OQSH6vg834ffz8NDd1BxfUICKFcbR8rBH/uhFI/0NaZNY0BiPE8mT6CqeCmflcsXYYzgnI4hUXzP8u2RNqIonuQZiJCokk77rF61jExYRRwn14E45whSHqd+O0MURZMjUFWsNQzl8ixduZEoSsbUrqhTjDUUCkXm3nk7zrn/TnCjUMCzljAbYKwhjuLyZTdBTDwi58hkM3x5YNvVEakqQcrj5Kk/2Lj5A6qrQyaGvgGBcw4MxFHE7n1fYIwpH/LI6Hp6r5BO+yNCMtf2VCZIqwijD6AEQSCYNMXefvYf+AaieMwuS5CpolAoUrwyiKqSzWYEVYzAKB6k1YOWocaGRe2zZpimrsuuENTWmL37D5V273rXbzvRItbacQpRVZxTRCCKImbV17Htw09KvmfIF9TNrjOpxoZUO7QMjTMcz7dRXBiUBQvusvPnNpg4SSaUoKriWcvFS7165Ojx2KZCTWL8HWurrxrOeMs8mJ/6Vx9RPj8Mw0Ud+wGPZwF8S1hTLfVT8dcvr2SZFUwfEbHG8K8ykfI95FxS2fSvtfv//Lb8DSk8L9046dAPAAAAAElFTkSuQmCC' },
    'pricing' => { 16 => 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAADKklEQVR4nHWTW2hcVRiF19p7nzM5c0smiSGKqCWt0NrSkElqlGrrDaYt1YcaLw8KGrDUB8GKlngLVTQIgr4KKSLoQ/UlUjAhJVCslNg4seKTbaPUllYpyclM5pKZc/b+fUmKoq6nf8HPx3r5KAKSEJFRH8UzO8OKTWmIBTWXylZqDYtbb/KptZVmTJ1L6yry935HHm2KgIaESL3QM/by9LHJuUZfFAu1UgCI7natMmmFC5drzjkHiMAYyp6B6XmpF4bJqQUjMhS8f/jK+HtfVHfVajbUvlZiG+LKS+6tF7uTTzyY8bc9/ntJZXIEAecoxfPxLiHGRYb2KpxbHJw628jX6jZsbzNKy6rc3JXla2+OBE8/c9DbsOURjhx9NUgGYCogc1mwVrfh1NlGHucWB01YQjqKQe1pVmsNueP22/T0ic9SmdZ2Ll/9EY20wsYNf6jmaoREMoHYCpUhohgMS0gb3yhLAiTZWKnI2LtHWiAOfYMHVoYfWEjcvb1TDx+8Vs12p5R1AkVAHEACvlHWWAtiPSSuX1+U7u4udWJiPO2HX+Hn059bKE2tFJwIALnxbi1o1otzTpLZDEbf+Wh1y+aN6r578gZ4CX+GaXdX75f6l4u/Wa01EwnvHxC1fogTGGO4XC5LYf+z1Yf3PVeZ/PrT6P7C8+anH6YyE8c/SXXk2hhFkVDx3wAAEBF4vgfPN5j55nRUnPnYXimOuktXS7KvsNv78IM3guZqE4q8QVBa/23PGkSRABxSSY/fzxy3/f17ymdm5+OB/HattIazDgCgNcQ0Y6dFAK5tUUqhUq7K4SOHWvY+udlztoaJnXemBvq3muFDIzUbx1AtAUSAZuy0ybWi4hmIi0VMkrACKkN0dnWyvc1D4FZ48cKyPDb0QmX65LdxWy6LpVLkPKNVrhUVg96O2cKOerF4Pt4dliVUysJ4AV9/5e06LnfxqYeS3qP7f61At9Bk01wqRS4Z6FxhR+IUejtmCQBSL/SMjZSOTc41+uJYSEW4mNi6yde3dGqenFuNNQFr7ZpMifmRsdZhBlML/D+dtad56VpTwjKwrccntBX7Hzr/BV1Hg1e7qnZJAAAAAElFTkSuQmCC', 24 => 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAE7ElEQVR4nJVWa2xURRT+zsy9u3v37i5l21oEFSqPYoMEKUQQNUElvjCGNNg/EHlFMFAh+osQ0jSRaECwPFQsAmqaEB6NicUgIpFAAsijNUQriQ1BpOHRdrHtvu69O3P80S5N2y3CSSb3JnPyfWfOnDnfIfQac5UgqtY9//NDgEMYZAW93/bBW/Az0cH4QCwCAK6qElRdrfnvl6Y1n/cWN7VkyphBRGDmHh8CkEgzux4jHCQYkogBZH2IwE+NMy6WTjf30uifL2QxKcvGLXPmbd8T/3JrfXL49Tbl9eIiC640Y8p4v4zmSWq67KhYl2JDEviuD+ORQmmuLg/eqVwSWk7jjn3HXCV6TtD68tTtn3UfWb29yxKSPMsP0ZM3QAiCaUjEul0+sW1k6PkXI8bcpf8kfjyb9sJBpozuS1LKgdaKza2VkVTlyvCrNOpoo2AGNZ9xl9bUJ6JSwrMtSGYQM0hIScmkg47b7WBPked6pDs7Ke14pDq7oHv9ssu2IKWEV1OfiDafcZcygwQw325qccta27Ub8JNQqicaKSW6Yv/yExPHys2fVFm/njoUnvHCAsPFZOzcucOq+eKjYCaj+l2zUkDAT6K1XbtNLW4ZMN82AOduBFnHLPiiRRW+rZvWW5GwTQCQSD4OTyuMC4XE6JaUSHYnORLNI6X6E/XhOWQMLDYhBFKJFCZPmSS3b66ygsEAfV5b53xd1+BuWe4EJxVLObsa8cstt7RlB0hrPRCiP14uAi8R54r5r5sh26JNNbudXXv2uefPNKp4dzubwkXjb3+otvYYGz4fmDkX7tAEvSyIx5MAgGefmWZcPN0Q3n+o1s7Pj1Im4yEvL4/8AfN/wXMSKKVgDYvQ7r0H3CtXr+tZT0+RqbSLt96cbU6fu0nGXYtjHTc4GU8zCYIQuWMckoCZYRgGOjpiumJhZfLchUvKDgYAABmrBOHJH9OyJQt8U54skalEmpOJFN+LJOeO1hp22KbGpt8zL85dGK94e3ViR22dE2v9k62CEny6cYN19mR9uOHQV6GJJWNlOjk0yZDUSinYEZu01jhwsMGrXL422fTDSmV2n+gJghmvzHnOOHb429DIUSOE6zggGtwf75lArTQEEYZHh5EZLaSAT9Cdpg+x55s61/L7kHYzeLiogKrXvx9wkumcp7j3DQFgABml4KVSIGGy6QthReW61LyKlYkt23alldIoGV8sYRo5q2rQQxtEwAyAEAiFyE13gjMBFBYMp5s323jWjDJDSoGfjp/y4GV6+/sDEEgp0dUR41XvLfOv/eBdPzs3SEQsHDsiQ6UlxQIATp6+mNm4eacTjIRyvmrRo0Rg6mvt/YykgQnjxogRD+WLonCcZPwcJhSHRfPlK7pqQ036tXmLE5oZQoi7KerD8zMxg5rrZ+94Y13snWu3VFfQIjmgdwHQyC8cSfvXkj21NCGXbrKT+w7fcJXbiWAkQllwKYFkitVjRTLSsCFaW1r+yypBBC6d6du9ptyOKQUzkYLKRpBdUgq+9tfVjGLWvkdHoe12m1ZKcUFhPoQgBjMTgRMpKKVgrim3Y6UzfbuJwEavZDZyy5wVAOeWTAKEFUDt993i+CWHr9wgk6SQ8VQGujexBMaYoqxk2ito1NHGPsm8T9G/E9fsuozoMAHTJGJ9H6LfV44PMrYAg0eX3GPLf3qNo75aCqweAAAAAElFTkSuQmCC' },
  }.freeze

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
      patch_local_gallery_index_html!
      if respond_to?(:open_dola_dialog)
        open_dola_dialog
        UI.start_timer(0.35, false) { inject_gallery_dressing_ui_into_dialog }
        UI.start_timer(1.0, false)  { inject_gallery_dressing_ui_into_dialog }
      end
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
      :preferences_key => 'DolaFloatingSliderBar_v4',
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
            background: linear-gradient(180deg, #070d1f 0%, #0c1734 55%, #060b18 100%);
            color: #f8fafc;
            overflow: hidden;
          }
          .slider-shell {
            display: flex;
            flex-direction: column;
            height: 100vh;
            padding: 8px 7px;
            gap: 6px;
            border: 1px solid rgba(229, 184, 66, 0.32);
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
            background: rgba(14, 25, 52, 0.88);
            border: 1px solid rgba(229, 184, 66, 0.22);
            color: #f8fafc;
            cursor: pointer;
            font-family: 'Tajawal', sans-serif;
            font-size: 12px;
            font-weight: 700;
            text-align: right;
            transition: all 0.16s ease;
          }
          .tool-btn:hover {
            background: rgba(26, 46, 92, 0.78);
            border-color: rgba(245, 200, 76, 0.85);
            transform: translateY(-1px);
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.32);
          }
          .tool-icon {
            width: 32px;
            height: 32px;
            border-radius: 9px;
            background: #091328;
            border: 1px solid rgba(245, 200, 76, 0.45);
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

  # 4) أداة اللزق والمحاذاة الذكية (Smart Face & Wall Point Snap Tool)
  class DolaClickSideSnapTool
    WALL_WORDS  = %w[حائط حوائط غرفة جدار حيطة حيطه مباني عمود_خرسانة wall walls room].freeze
    UPPER_WORDS = %w[علوي علوية قلاب معلق شفاط ميكروويف wall_unit upper].freeze
    TALL_WORDS  = %w[دولاب بانتري ثلاجة فرن نيش دريسنج دريسينج عمود tall wardrobe dressing].freeze
    DOOR_WORDS  = %w[ضلفة ضلفه ضلف باب ابواب وش مقبض door front drawer_front].freeze
    BACK_WORDS  = %w[ضهر ظهر ظهريه ظهرية ضهريه ضهرية back].freeze
    SIDE_WORDS  = %w[جنب جانب قاطوع قاطع side partition].freeze

    def initialize
      @moving_unit       = nil
      @source_face       = nil
      @hover_unit        = nil
      @hover_face        = nil
      @hover_wall        = nil
      @preview_ghost_pts = nil
      @preview_info_text = ''
      # وضع ارتفاع الدولاب على الحائط أو بجانب السفلي:
      # :base_bottom = يمشي مع بداية السفلي من تحت (أو الأرضية)
      # :top_220     = يمشي من فوق عند 2.20 متر
      @tall_wall_mode    = :base_bottom
    end

    def activate
      @moving_unit       = nil
      @source_face       = nil
      @hover_unit        = nil
      @hover_face        = nil
      @hover_wall        = nil
      @preview_ghost_pts = nil
      update_status_prompt
      Sketchup.active_model.active_view.invalidate
    end

    def deactivate(view)
      @moving_unit       = nil
      @source_face       = nil
      @hover_unit        = nil
      @hover_face        = nil
      @hover_wall        = nil
      @preview_ghost_pts = nil
      view.invalidate if view
    end

    def onCancel(_reason, view)
      if @moving_unit
        @moving_unit       = nil
        @source_face       = nil
        @preview_ghost_pts = nil
        update_status_prompt
        view.invalidate if view
      else
        Sketchup.active_model.select_tool(nil)
      end
    end

    def onKeyDown(key, _repeat, _flags, view)
      if key == 9 || key == VK_UP || key == VK_DOWN
        @tall_wall_mode = (@tall_wall_mode == :base_bottom) ? :top_220 : :base_bottom
        mode_lbl = (@tall_wall_mode == :base_bottom) ? 'الدولاب مع بداية السفلي من أسفل' : 'الدولاب عند سقف 2.20 متر من أعلى'
        Sketchup.status_text = "🧲 تم تبديل وضع الدولاب إلى: [#{mode_lbl}] (اضغط Tab للتبديل)"
        recompute_preview(view)
        view.invalidate if view
        return true
      end
      false
    rescue
      false
    end

    def getMenu(menu, _flags, _x, _y, view)
      menu.add_item('🧲 وضع الدولاب على الحائط: مع بداية السفلي من أسفل') do
        @tall_wall_mode = :base_bottom
        recompute_preview(view)
        view.invalidate if view
      end
      menu.add_item('🧲 وضع الدولاب على الحائط: سقف 2.20 متر من أعلى') do
        @tall_wall_mode = :top_220
        recompute_preview(view)
        view.invalidate if view
      end
      if @moving_unit
        menu.add_separator
        menu.add_item('🔄 إلغاء تحديد القطعة الحالية واختيار قطعة أخرى') do
          @moving_unit = nil
          @source_face = nil
          @preview_ghost_pts = nil
          update_status_prompt
          view.invalidate if view
        end
      end
    rescue
    end

    # دالة إزاحة نقطة بأمان تام في SketchUp بدون خطأ ArgumentError عندما تكون المسافة صفراً
    def offset_pt(pt, vec, dist)
      d = dist.to_f
      return Geom::Point3d.new(pt.x, pt.y, pt.z) if d.abs < 1e-8
      Geom::Point3d.new(
        pt.x + vec.x * d,
        pt.y + vec.y * d,
        pt.z + vec.z * d
      )
    end

    # دالة عكس اتجاه متجه بأمان تام في SketchUp (لأن Geom::Vector3d لا يدعم -vec أحادي في كل الإصدارات)
    def rev_vec(vec)
      Geom::Vector3d.new(-vec.x.to_f, -vec.y.to_f, -vec.z.to_f)
    end

    def update_status_prompt
      tall_txt = (@tall_wall_mode == :base_bottom) ? 'بداية السفلي' : 'سقف 2.20م'
      if @moving_unit.nil? || @source_face.nil?
        Sketchup.status_text = "🧲 الخطوة 1: اضغط على الجنب أو الوش أو الظهر المراد اللزق منه في القطعة الأولى | وضع الدولاب (Tab): #{tall_txt}"
      else
        Sketchup.status_text = "🧲 الخطوة 2 [تم تحديد: #{@source_face[:label]}]: اضغط الآن على الحائط أو على جنب/وش/ظهر القطعة الثانية للزق | وضع الدولاب (Tab): #{tall_txt}"
      end
    end

    # هل الكونتينر يمثل وحدة مطبخ أو دريسينج؟
    def cabinet_unit_entity?(ent)
      return false unless ent && ent.valid?
      return false unless ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)
      if ent.respond_to?(:attribute_dictionary)
        return true if ent.attribute_dictionary('dynamic_attributes', false)
        return true if ent.attribute_dictionary('MHD_DRESSING', false)
        return true if ent.attribute_dictionary(PREF_NS, false)
      end
      if ent.respond_to?(:definition) && ent.definition
        return true if ent.definition.attribute_dictionary('dynamic_attributes', false)
        return true if ent.definition.attribute_dictionary('MHD_DRESSING', false)
      end
      false
    rescue
      false
    end

    # فحص هل الكونتينر (Group / ComponentInstance) يمثل حائطاً أو غرفة حوائط
    # ملاحظة مهمة: لا نرجع true لمجرد كون العنصر Sketchup::Face حتى لا تُصنّف أوجه الوحدات كحوائط!
    def wall_container?(ent)
      return false unless ent && ent.valid?
      return false unless ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
      return false if cabinet_unit_entity?(ent)

      if ent.respond_to?(:get_attribute)
        return true if ent.get_attribute('MHD_ROOM_BUILDER', 'النوع', nil).to_s == 'حائط'
        return true if ent.attribute_dictionary('MHD_ROOM_BUILDER', false)
        return true if ent.attribute_dictionary('DolaWallDrawer', false)
      end

      nm = [
        ent.respond_to?(:name) ? ent.name.to_s : '',
        (ent.respond_to?(:definition) && ent.definition) ? ent.definition.name.to_s : '',
        (ent.respond_to?(:layer) && ent.layer) ? ent.layer.name.to_s : ''
      ].join(' ').downcase
      return true if WALL_WORDS.any? { |w| nm.include?(w) }

      if ent.is_a?(Sketchup::Group)
        sub_walls = ent.entities.grep(Sketchup::Group).any? do |g|
          g.get_attribute('MHD_ROOM_BUILDER', 'النوع', nil).to_s == 'حائط' ||
            g.attribute_dictionary('DolaWallDrawer', false) ||
            WALL_WORDS.any? { |w| g.name.to_s.downcase.include?(w) }
        end
        return true if sub_walls
      end
      false
    rescue
      false
    end

    # توافق مع أي استدعاء داخلي لـ wall_entity?
    def wall_entity?(ent)
      wall_container?(ent)
    end

    # تصنيف الوحدة لتحديد الارتفاع القياسي على الحائط:
    # :upper => وحدة علوية (سقفها عند 220 سم)
    # :base  => وحدة سفلية (سقفها عند 90 سم)
    # :tall  => دولاب / وحدة طويلة (حسب الخيار: بداية السفلي أو سقف 220 سم)
    def classify_unit_category(unit)
      return :base unless unit && unit.valid?
      if DolaSmartLibraryPlugin.respond_to?(:dressing_unit_type)
        dt = DolaSmartLibraryPlugin.dressing_unit_type(unit).to_s
        return :tall unless dt.empty?
      end
      if unit.respond_to?(:attribute_dictionary) && unit.attribute_dictionary('MHD_DRESSING', false)
        return :tall
      end
      if unit.respond_to?(:definition) && unit.definition && unit.definition.attribute_dictionary('MHD_DRESSING', false)
        return :tall
      end

      bb = unit.bounds
      h_cm     = bb.height.to_f * 2.54
      z_min_cm = bb.min.z.to_f * 2.54
      nm = [
        unit.respond_to?(:name) ? unit.name.to_s : '',
        (unit.respond_to?(:definition) && unit.definition) ? unit.definition.name.to_s : '',
        DolaSmartLibraryPlugin.resolve_library_unit_display_name(unit).to_s
      ].join(' ').downcase

      return :tall if h_cm >= 145.0 || TALL_WORDS.any? { |w| nm.include?(w) }
      return :upper if UPPER_WORDS.any? { |w| nm.include?(w) } || z_min_cm >= 100.0
      :base
    rescue
      :base
    end

    # البحث عن أوطى منسوب (min_z) للوحدات السفلية في المشهد لمحاذاة بداية الدولاب معها
    def find_nearby_base_bottom_z(exclude_unit = nil)
      model = Sketchup.active_model
      base_z_list = []
      model.active_entities.each do |e|
        next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        next if e == exclude_unit || !e.valid? || wall_container?(e)
        if classify_unit_category(e) == :base
          base_z_list << e.bounds.min.z.to_f
        end
      end
      return 0.0 if base_z_list.empty?
      base_z_list.min
    rescue
      0.0
    end

    # تحديد اتجاه الوش/الضلفة والظهر في محاور الوحدة المحلية
    def detect_front_is_min_y?(unit)
      ents = if unit.respond_to?(:definition) && unit.definition
               unit.definition.entities
             elsif unit.respond_to?(:entities)
               unit.entities
             else
               nil
             end
      return true unless ents
      front_ys = []
      back_ys  = []
      ents.each do |e|
        next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        nm = "#{e.name} #{e.respond_to?(:definition) && e.definition ? e.definition.name : ''}".downcase
        cy = e.bounds.center.y.to_f
        if DOOR_WORDS.any? { |w| nm.include?(w) }
          front_ys << cy
        elsif BACK_WORDS.any? { |w| nm.include?(w) }
          back_ys << cy
        end
      end
      if !front_ys.empty? && !back_ys.empty?
        avg_f = front_ys.inject(0.0, :+) / front_ys.length
        avg_b = back_ys.inject(0.0, :+) / back_ys.length
        return avg_f <= avg_b
      end
      true
    rescue
      true
    end

    # استخراج أركان الكونتينر محلياً لتحويلها لأي إحداثيات عالمية بدقة
    def entity_local_bounds(ent)
      if ent.respond_to?(:definition) && ent.definition
        ent.definition.bounds
      elsif ent.respond_to?(:local_bounds)
        ent.local_bounds
      else
        ent.bounds
      end
    rescue
      ent.bounds
    end

    # حساب إطار الوحدة والـ 4 أوجه الرأسية (الجنب اليمين، الجنب الشمال، الوش/الضلفة، الظهر)
    def compute_unit_frame_and_faces(unit)
      tr = unit.transformation
      origin = tr.origin
      ux = Geom::Vector3d.new(tr.xaxis.x, tr.xaxis.y, 0.0)
      uy = Geom::Vector3d.new(tr.yaxis.x, tr.yaxis.y, 0.0)
      ux = Geom::Vector3d.new(1, 0, 0) if ux.length < 1e-6
      uy = Geom::Vector3d.new(0, 1, 0) if uy.length < 1e-6
      ux.normalize!
      uy.normalize!
      uz = Geom::Vector3d.new(0, 0, 1)

      if ux.cross(uy).z < 0
        ux = rev_vec(ux)
      end

      # حساب أركان الوحدة في الإحداثيات العالمية بدقة من الـ local bounds
      lbb = entity_local_bounds(unit)
      corners = (0..7).map { |i| lbb.corner(i).transform(tr) }
      if corners.empty?
        bb = unit.bounds
        corners = (0..7).map { |i| bb.corner(i) }
      end

      xs = corners.map { |p| (p - origin).dot(ux) }
      ys = corners.map { |p| (p - origin).dot(uy) }
      zs = corners.map(&:z)

      min_x, max_x = xs.min, xs.max
      min_y, max_y = ys.min, ys.max
      min_z, max_z = zs.min, zs.max

      front_min_y = detect_front_is_min_y?(unit)
      min_y_label = front_min_y ? 'الوش / الضلفة' : 'الظهر'
      max_y_label = front_min_y ? 'الظهر' : 'الوش / الضلفة'
      min_y_role  = front_min_y ? :front : :back
      max_y_role  = front_min_y ? :back : :front

      build_face = lambda do |key, role, label, normal, axis_u, p_coord, u_min, u_max, f_min_z = min_z, f_max_z = max_z|
        axis_p = (key == :min_x || key == :max_x) ? ux : uy
        base_pt = offset_pt(origin, axis_p, p_coord)
        c0 = offset_pt(base_pt, axis_u, u_min)
        c1 = offset_pt(base_pt, axis_u, u_max)
        p0 = Geom::Point3d.new(c0.x, c0.y, f_min_z)
        p1 = Geom::Point3d.new(c1.x, c1.y, f_min_z)
        p2 = Geom::Point3d.new(c1.x, c1.y, f_max_z)
        p3 = Geom::Point3d.new(c0.x, c0.y, f_max_z)
        center = Geom::Point3d.new((p0.x + p2.x) * 0.5, (p0.y + p2.y) * 0.5, (f_min_z + f_max_z) * 0.5)
        {
          :key        => key,
          :role       => role,
          :label      => label,
          :normal     => normal,
          :axis_p     => axis_p,
          :axis_u     => axis_u,
          :base_pt    => base_pt,
          :p_coord    => p_coord,
          :u_min      => u_min,
          :u_max      => u_max,
          :min_z      => f_min_z,
          :max_z      => f_max_z,
          :unit_min_z => min_z,
          :unit_max_z => max_z,
          :quad       => [p0, p1, p2, p3],
          :center     => center
        }
      end

      faces = [
        build_face.call(:min_x, :left,       'الجنب الشمال', rev_vec(ux), uy, min_x, min_y, max_y),
        build_face.call(:max_x, :right,      'الجنب اليمين', ux,          uy, max_x, min_y, max_y),
        build_face.call(:min_y, min_y_role,  min_y_label,    rev_vec(uy), ux, min_y, min_x, max_x),
        build_face.call(:max_y, max_y_role,  max_y_label,    uy,          ux, max_y, min_x, max_x)
      ]

      {
        :origin     => origin,
        :ux         => ux,
        :uy         => uy,
        :uz         => uz,
        :min_x      => min_x, :max_x => max_x,
        :min_y      => min_y, :max_y => max_y,
        :min_z      => min_z, :max_z => max_z,
        :build_face => build_face,
        :faces      => faces
      }
    end

    # اختيار الوجه الأدق من الوحدة مع دعم اللزق على حدود الجروب الداخلي الغاطس أو الفعلي الذي نقر عليه المستخدم
    def pick_unit_face_at(view, x, y, unit, hit_pt = nil, path = nil, leaf_tr = nil)
      frame = compute_unit_frame_and_faces(unit)
      ray   = view.pickray(x, y)
      r_org = ray[0]
      r_dir = ray[1]

      # استخراج الجروب الداخلي الفرعي (إن وجد داخل المكون الرئيسي) والوجه الملموس
      inner_grp    = nil
      inner_tr     = nil
      clicked_face = nil

      if path.is_a?(Array) && path.length > 1
        clicked_face = path.reverse.find { |e| e.is_a?(Sketchup::Face) }
        # نبحث عن أعمق جروب/مكون فرعي داخل الوحدة الرئيسية يمثل القطعة الملموسة (مثل الجنب الغاطس أو الضلفة أو الظهر)
        cum_tr = Geom::Transformation.new
        path.each_with_index do |ent, idx|
          if ent.respond_to?(:transformation)
            cum_tr = cum_tr * ent.transformation
            if idx > 0 && (ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance))
              inner_grp = ent
              inner_tr  = cum_tr
            end
          end
        end
      end

      leaf_role_hint = nil
      if inner_grp
        lnm = "#{inner_grp.respond_to?(:name) ? inner_grp.name : ''} #{inner_grp.respond_to?(:definition) && inner_grp.definition ? inner_grp.definition.name : ''}".downcase
        leaf_role_hint = :front if DOOR_WORDS.any? { |w| lnm.include?(w) }
        leaf_role_hint = :back  if BACK_WORDS.any? { |w| lnm.include?(w) }
      end

      # اتجاه العمودي للوجه الملموس فعلياً بالماوس (إن وجد)
      clicked_face_normal = nil
      if clicked_face && leaf_tr
        fn = clicked_face.normal.transform(leaf_tr)
        fn_h = Geom::Vector3d.new(fn.x, fn.y, 0.0)
        if fn_h.length > 1e-4
          fn_h.normalize!
          fn_h = rev_vec(fn_h) if fn_h.dot(r_dir) > 0
          clicked_face_normal = fn_h
        end
      end

      # تحليل أبعاد الجروب الداخلي الفرعي (إن وجد) لمعرفة ما إذا كان لوحاً جانبياً أو خلفياً أو ضلفة غاطسة
      inner_stats = nil
      if inner_grp && inner_tr
        ibb = entity_local_bounds(inner_grp)
        icorns = (0..7).map { |i| ibb.corner(i).transform(inner_tr) }
        ixs = icorns.map { |p| (p - frame[:origin]).dot(frame[:ux]) }
        iys = icorns.map { |p| (p - frame[:origin]).dot(frame[:uy]) }
        izs = icorns.map(&:z)
        inner_stats = {
          :min_x => ixs.min, :max_x => ixs.max, :span_x => (ixs.max - ixs.min),
          :min_y => iys.min, :max_y => iys.max, :span_y => (iys.max - iys.min),
          :min_z => izs.min, :max_z => izs.max
        }
      end

      best_face = nil
      best_score = Float::INFINITY

      if hit_pt
        frame[:faces].each do |f|
          # إذا كان المستخدم ضاغط على جروب داخلي (مثلاً جنب غاطس)، نقيس المسافة بالنسبة لحدود الجروب الداخلي أو الوجه الفعلي
          ref_p_coord = f[:p_coord]
          if inner_stats
            case f[:key]
            when :min_x then ref_p_coord = inner_stats[:min_x] if inner_stats[:span_x] <= 10.cm
            when :max_x then ref_p_coord = inner_stats[:max_x] if inner_stats[:span_x] <= 10.cm
            when :min_y then ref_p_coord = inner_stats[:min_y] if inner_stats[:span_y] <= 10.cm
            when :max_y then ref_p_coord = inner_stats[:max_y] if inner_stats[:span_y] <= 10.cm
            end
          end

          hit_p = (hit_pt - frame[:origin]).dot(f[:axis_p])
          d_plane = (hit_p - ref_p_coord).abs

          # مكافأة قوية إذا كان العمودي للوجه الملموس مطابقاً لاتجاه هذا الجنب/الوجه
          normal_bonus = 0.0
          if clicked_face_normal
            dot_n = clicked_face_normal.dot(f[:normal])
            if dot_n > 0.80
              normal_bonus = -15.cm
            elsif dot_n < -0.50
              normal_bonus = 20.cm
            end
          end

          # إذا كان الجروب الداخلي لوحاً رفيعاً باتجاه محور X (أي جنب يمين/شمال غاطس أو بارز)، نفضّل الجنب الأقرب لمركزه
          thin_board_bonus = 0.0
          if inner_stats
            unit_cx = (frame[:min_x] + frame[:max_x]) * 0.5
            unit_cy = (frame[:min_y] + frame[:max_y]) * 0.5
            inner_cx = (inner_stats[:min_x] + inner_stats[:max_x]) * 0.5
            inner_cy = (inner_stats[:min_y] + inner_stats[:max_y]) * 0.5
            if inner_stats[:span_x] <= 6.cm && inner_stats[:span_y] >= 12.cm
              if f[:key] == :min_x && inner_cx <= unit_cx
                thin_board_bonus = -18.cm
              elsif f[:key] == :max_x && inner_cx > unit_cx
                thin_board_bonus = -18.cm
              end
            elsif inner_stats[:span_y] <= 6.cm && inner_stats[:span_x] >= 12.cm
              if f[:key] == :min_y && inner_cy <= unit_cy
                thin_board_bonus = -18.cm
              elsif f[:key] == :max_y && inner_cy > unit_cy
                thin_board_bonus = -18.cm
              end
            end
          end

          facing_bonus = (f[:normal].dot(r_dir) < 0.18) ? 0.0 : 12.cm
          role_bonus   = (leaf_role_hint && f[:role] == leaf_role_hint) ? -10.cm : 0.0
          score = d_plane + facing_bonus + role_bonus + normal_bonus + thin_board_bonus

          if score < best_score
            best_score = score
            best_face  = f.dup
          end
        end
      end

      # احتياطي: تقاطع شعاع الكاميرا مع أوجه الصندوق المحيط
      unless best_face
        frame[:faces].each do |f|
          denom = r_dir.dot(f[:normal])
          next if denom.abs < 1e-6
          t = (f[:base_pt] - r_org).dot(f[:normal]) / denom
          next if t <= 0
          ipt = offset_pt(r_org, r_dir, t)
          u_val = (ipt - frame[:origin]).dot(f[:axis_u])
          next if u_val < f[:u_min] - 5.cm || u_val > f[:u_max] + 5.cm
          next if ipt.z < f[:min_z] - 5.cm || ipt.z > f[:max_z] + 5.cm
          if t < best_score
            best_score = t
            best_face  = f.dup
            hit_pt     = ipt
          end
        end
      end

      return nil unless best_face

      # الآن نضبط مستوى اللزق (base_pt و quad) ليكون على حدود الجروب الداخلي الغاطس/الفعلي الذي لمسه المستخدم!
      actual_p_coord = best_face[:p_coord]
      actual_u_min   = best_face[:u_min]
      actual_u_max   = best_face[:u_max]
      actual_min_z   = best_face[:min_z]
      actual_max_z   = best_face[:max_z]
      recessed_part  = false

      if inner_stats
        case best_face[:key]
        when :min_x
          if inner_stats[:span_x] <= 12.cm
            actual_p_coord = inner_stats[:min_x]
            actual_u_min   = inner_stats[:min_y]
            actual_u_max   = inner_stats[:max_y]
            recessed_part  = (actual_p_coord - best_face[:p_coord]).abs > 0.05.cm
          elsif clicked_face_normal && clicked_face_normal.dot(best_face[:normal]) > 0.85 && hit_pt
            actual_p_coord = (hit_pt - frame[:origin]).dot(best_face[:axis_p])
            recessed_part  = (actual_p_coord - best_face[:p_coord]).abs > 0.05.cm
          end
        when :max_x
          if inner_stats[:span_x] <= 12.cm
            actual_p_coord = inner_stats[:max_x]
            actual_u_min   = inner_stats[:min_y]
            actual_u_max   = inner_stats[:max_y]
            recessed_part  = (actual_p_coord - best_face[:p_coord]).abs > 0.05.cm
          elsif clicked_face_normal && clicked_face_normal.dot(best_face[:normal]) > 0.85 && hit_pt
            actual_p_coord = (hit_pt - frame[:origin]).dot(best_face[:axis_p])
            recessed_part  = (actual_p_coord - best_face[:p_coord]).abs > 0.05.cm
          end
        when :min_y
          if inner_stats[:span_y] <= 12.cm
            actual_p_coord = inner_stats[:min_y]
            actual_u_min   = inner_stats[:min_x]
            actual_u_max   = inner_stats[:max_x]
            recessed_part  = (actual_p_coord - best_face[:p_coord]).abs > 0.05.cm
          elsif clicked_face_normal && clicked_face_normal.dot(best_face[:normal]) > 0.85 && hit_pt
            actual_p_coord = (hit_pt - frame[:origin]).dot(best_face[:axis_p])
            recessed_part  = (actual_p_coord - best_face[:p_coord]).abs > 0.05.cm
          end
        when :max_y
          if inner_stats[:span_y] <= 12.cm
            actual_p_coord = inner_stats[:max_y]
            actual_u_min   = inner_stats[:min_x]
            actual_u_max   = inner_stats[:max_x]
            recessed_part  = (actual_p_coord - best_face[:p_coord]).abs > 0.05.cm
          elsif clicked_face_normal && clicked_face_normal.dot(best_face[:normal]) > 0.85 && hit_pt
            actual_p_coord = (hit_pt - frame[:origin]).dot(best_face[:axis_p])
            recessed_part  = (actual_p_coord - best_face[:p_coord]).abs > 0.05.cm
          end
        end
      elsif clicked_face_normal && clicked_face_normal.dot(best_face[:normal]) > 0.85 && hit_pt
        actual_p_coord = (hit_pt - frame[:origin]).dot(best_face[:axis_p])
        recessed_part  = (actual_p_coord - best_face[:p_coord]).abs > 0.05.cm
      end

      lbl = best_face[:label]
      lbl = "#{lbl} (حدود الجروب الداخلي)" if recessed_part

      updated_face = frame[:build_face].call(
        best_face[:key],
        best_face[:role],
        lbl,
        best_face[:normal],
        best_face[:axis_u],
        actual_p_coord,
        actual_u_min,
        actual_u_max,
        actual_min_z,
        actual_max_z
      )

      ref_pt    = hit_pt || updated_face[:center]
      u_val     = (ref_pt - frame[:origin]).dot(updated_face[:axis_u])
      u_clamped = [[u_val, updated_face[:u_min]].max, updated_face[:u_max]].min
      z_clamped = [[ref_pt.z, updated_face[:min_z]].max, updated_face[:max_z]].min
      pt_on_face = offset_pt(updated_face[:base_pt], updated_face[:axis_u], u_clamped)
      updated_face[:u_click]  = u_clamped
      updated_face[:click_pt] = Geom::Point3d.new(pt_on_face.x, pt_on_face.y, z_clamped)
      updated_face
    end

    # استخراج بيانات الحائط من مسار الالتقاط
    def extract_wall_target(root, face, tr, hit_pt, ray)
      return nil unless face && face.is_a?(Sketchup::Face)
      w_norm = tr ? face.normal.transform(tr) : face.normal
      w_norm = Geom::Vector3d.new(w_norm.x, w_norm.y, 0.0)
      return nil if w_norm.length <= 1e-4
      w_norm.normalize!
      # توجيه العمودي نحو داخل الغرفة (باتجاه الكاميرا)
      w_norm = rev_vec(w_norm) if w_norm.dot(ray[1]) > 0
      f_vtx  = tr ? face.vertices.first.position.transform(tr) : face.vertices.first.position
      if hit_pt
        dist_to_plane = (hit_pt - f_vtx).dot(w_norm)
        plane_pt = offset_pt(hit_pt, w_norm, -dist_to_plane)
      else
        denom = ray[1].dot(w_norm)
        t = denom.abs > 1e-5 ? ((f_vtx - ray[0]).dot(w_norm) / denom) : 0.0
        plane_pt = offset_pt(ray[0], ray[1], t)
      end
      axis_u = Geom::Vector3d.new(0, 0, 1).cross(w_norm)
      axis_u.normalize!
      {
        :kind     => :wall,
        :root     => root,
        :normal   => w_norm,
        :axis_u   => axis_u,
        :click_pt => plane_pt,
        :label    => 'الحائط'
      }
    rescue
      nil
    end

    # تحليل ما تحت مؤشر الماوس (إما حائط أو وحدة مطبخ/دريسينج)
    def analyze_hover_target(view, x, y)
      ph = view.pick_helper
      ph.do_pick(x, y)
      ip = Sketchup::InputPoint.new
      ip.pick(view, x, y)
      hit_pt = ip.valid? ? ip.position : nil

      ray = view.pickray(x, y)

      (0...ph.count).each do |idx|
        path = ph.path_at(idx)
        next unless path && !path.empty?
        root = path.first
        tr   = ph.transformation_at(idx)

        # إذا كان العنصر هو الوحدة المتحركة نفسها في الخطوة 2 نتجاهله لنلتقط ما خلفه/بجانبه
        next if @moving_unit && @source_face && root == @moving_unit

        # 1) إذا كان الجذر وجه حائط حر غير مجمع (Ungrouped Face)
        if root.is_a?(Sketchup::Face)
          w_info = extract_wall_target(root, root, Geom::Transformation.new, hit_pt, ray)
          return w_info if w_info
          next
        end

        # 2) هل أحد الكونتينرات في المسار يمثل حائطاً؟
        if path.any? { |e| wall_container?(e) }
          face = path.reverse.find { |e| e.is_a?(Sketchup::Face) }
          w_info = extract_wall_target(root, face, tr, hit_pt, ray)
          return w_info if w_info
          next
        end

        # 3) في الخطوة 2 فقط: إذا كان المستخدم رسم حائطاً كـ Group عادي كبير (بدون اسم حائط وبدون خصائص وحدات أو جروبات فرعية)
        if @moving_unit && @source_face && root.is_a?(Sketchup::Group) && !cabinet_unit_entity?(root)
          has_sub_containers = root.entities.any? { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
          rbb = root.bounds
          max_horiz = [rbb.width.to_f, rbb.height.to_f].max
          if !has_sub_containers && max_horiz >= 220.cm && rbb.depth.to_f >= 180.cm
            face = path.reverse.find { |e| e.is_a?(Sketchup::Face) }
            w_info = extract_wall_target(root, face, tr, hit_pt, ray)
            return w_info if w_info
          end
        end

        # 4) العنصر الرئيسي وحدة (ComponentInstance أو Group)
        if (root.is_a?(Sketchup::ComponentInstance) || root.is_a?(Sketchup::Group)) && !wall_container?(root)
          u_face = pick_unit_face_at(view, x, y, root, hit_pt, path, tr)
          if u_face
            return {
              :kind => :unit,
              :unit => root,
              :face => u_face
            }
          end
        end
      end

      nil
    rescue
      nil
    end

    # حساب مصفوفة التحويل النهائية للوحدة المتحركة (بدون تطبيقها بعد، لاستخدامها في المعاينة الحية والتنفيذ)
    def compute_snap_transformation(moving, src_face, target_info)
      return nil unless moving && moving.valid? && src_face && target_info

      # 1) زاوية التدوير الأفقية: نجعل العمودي الخارج للوجه المختار في القطعة الأولى عكس العمودي للهدف تماماً (N1_new = -N_target)
      n1 = Geom::Vector3d.new(src_face[:normal].x, src_face[:normal].y, 0.0)
      nt = Geom::Vector3d.new(target_info[:normal].x, target_info[:normal].y, 0.0)
      return nil if n1.length < 1e-5 || nt.length < 1e-5
      n1.normalize!
      nt.normalize!

      desired_n1 = rev_vec(nt)
      ang1 = Math.atan2(n1.y, n1.x)
      ang2 = Math.atan2(desired_n1.y, desired_n1.x)
      delta_angle = ang2 - ang1

      pivot = src_face[:click_pt] || moving.bounds.center
      rot_tr = Geom::Transformation.rotation(pivot, Geom::Vector3d.new(0, 0, 1), delta_angle)

      # حساب مواضع أركان الوحدة المتحركة والوجه المختار بعد التدوير
      lbb = entity_local_bounds(moving)
      rot_tr_full = rot_tr * moving.transformation
      rot_corners = (0..7).map { |i| lbb.corner(i).transform(rot_tr_full) }
      rot_min_z = rot_corners.map(&:z).min
      rot_max_z = rot_corners.map(&:z).max

      rot_quad = src_face[:quad].map { |p| p.transform(rot_tr) }
      rot_click_pt = (src_face[:click_pt] || src_face[:center]).transform(rot_tr)

      # محور الامتداد الأفقي للهدف (T_target) والعمودي (N_target)
      t_vec = Geom::Vector3d.new(0, 0, 1).cross(nt)
      t_vec.normalize!

      target_pt = target_info[:click_pt]

      # 2) الإزاحة العمودية على وجه الهدف (انطباق حدود الجروب الداخلي/الوجه المختار تماماً بدون فراغ أو تداخل)
      plane_point_src = rot_quad.first
      dn = (target_pt - plane_point_src).dot(nt)

      # 3) الإزاحة الأفقية على امتداد وجه الهدف (في نفس المكان الذي ضغط عليه المستخدم)
      src_u_vals = rot_quad.map { |p| (p - target_pt).dot(t_vec) }
      src_u_min  = src_u_vals.min
      src_u_max  = src_u_vals.max
      src_width  = src_u_max - src_u_min
      click_u    = (rot_click_pt - target_pt).dot(t_vec)

      if target_info[:kind] == :unit && target_info[:face]
        tf = target_info[:face]
        tgt_quad_u = tf[:quad].map { |p| (p - target_pt).dot(t_vec) }
        tgt_u_min  = tgt_quad_u.min
        tgt_u_max  = tgt_quad_u.max
        tgt_width  = tgt_u_max - tgt_u_min

        rel_click_src = src_width > 1e-4 ? ((click_u - src_u_min) / src_width) : 0.5
        rel_click_tgt = tgt_width > 1e-4 ? ((0.0 - tgt_u_min) / tgt_width) : 0.5
        if (src_width - tgt_width).abs <= 6.cm && rel_click_src.between?(0.2, 0.8) && rel_click_tgt.between?(0.2, 0.8)
          src_center_u = (src_u_min + src_u_max) * 0.5
          tgt_center_u = (tgt_u_min + tgt_u_max) * 0.5
          dt = tgt_center_u - src_center_u
        elsif rel_click_src <= 0.2
          dt = -src_u_min
        elsif rel_click_src >= 0.8
          dt = -src_u_max
        else
          dt = -click_u
        end
      else
        rel_click_src = src_width > 1e-4 ? ((click_u - src_u_min) / src_width) : 0.5
        if rel_click_src <= 0.22
          dt = -src_u_min
        elsif rel_click_src >= 0.78
          dt = -src_u_max
        else
          dt = -click_u
        end
      end

      # 4) ضبط الارتفاع الرأسي (Z) تلقائياً حسب نوع الهدف ونوع الوحدة
      cat = classify_unit_category(moving)
      if target_info[:kind] == :unit && target_info[:unit] && target_info[:unit].valid?
        tgt_unit = target_info[:unit]
        tgt_bb   = tgt_unit.bounds
        tgt_cat  = classify_unit_category(tgt_unit)
        if cat == :tall && tgt_cat == :base && @tall_wall_mode == :base_bottom
          dz = tgt_bb.min.z.to_f - rot_min_z
          z_desc = 'بداية السفلي من أسفل'
        else
          dz = tgt_bb.max.z.to_f - rot_max_z
          z_desc = "تساوي السقف من أعلى (#{((tgt_bb.max.z.to_f) * 2.54).round(1)} سم)"
        end
      else
        case cat
        when :upper
          dz = 220.cm - rot_max_z
          z_desc = 'وحدة علوية — السقف عند 2.20 متر'
        when :base
          dz = 90.cm - rot_max_z
          z_desc = 'وحدة سفلية — السقف عند 90 سم'
        when :tall
          if @tall_wall_mode == :top_220
            dz = 220.cm - rot_max_z
            z_desc = 'دولاب — السقف عند 2.20 متر (Tab للتبديل لبداية السفلي)'
          else
            base_z = find_nearby_base_bottom_z(moving)
            dz = base_z - rot_min_z
            z_desc = "دولاب — بداية السفلي (#{(base_z * 2.54).round(1)} سم) (Tab للتبديل لسقف 2.20م)"
          end
        else
          dz = 90.cm - rot_max_z
          z_desc = 'السقف عند 90 سم'
        end
      end

      move_vec = Geom::Vector3d.new(
        nt.x * dn + t_vec.x * dt,
        nt.y * dn + t_vec.y * dt,
        dz
      )
      final_tr = Geom::Transformation.translation(move_vec) * rot_tr
      ghost_pts = rot_corners.map { |p| Geom::Point3d.new(p.x + move_vec.x, p.y + move_vec.y, p.z + move_vec.z) }

      {
        :transform  => final_tr,
        :ghost_pts  => ghost_pts,
        :z_desc     => z_desc
      }
    rescue
      nil
    end

    def recompute_preview(view)
      return unless @moving_unit && @source_face
      target_info = if @hover_wall
                      @hover_wall
                    elsif @hover_unit && @hover_face
                      {
                        :kind     => :unit,
                        :unit     => @hover_unit,
                        :face     => @hover_face,
                        :normal   => @hover_face[:normal],
                        :click_pt => @hover_face[:click_pt],
                        :label    => @hover_face[:label]
                      }
                    else
                      nil
                    end
      if target_info
        res = compute_snap_transformation(@moving_unit, @source_face, target_info)
        if res
          @preview_ghost_pts = res[:ghost_pts]
          @preview_info_text = res[:z_desc]
          Sketchup.status_text = "🧲 جاهز للزق: [#{@source_face[:label]}] ⬅ [#{target_info[:label]}] | الارتفاع: #{res[:z_desc]}"
          return
        end
      end
      @preview_ghost_pts = nil
    end

    def onMouseMove(_flags, x, y, view)
      hit = analyze_hover_target(view, x, y)
      @hover_wall = nil
      @hover_unit = nil
      @hover_face = nil

      if @moving_unit.nil? || @source_face.nil?
        if hit && hit[:kind] == :unit
          @hover_unit = hit[:unit]
          @hover_face = hit[:face]
          Sketchup.status_text = "🧲 الخطوة 1: اضغط كليك شمال لاختيار «#{@hover_face[:label]}» من هذه القطعة."
        else
          update_status_prompt
        end
      else
        if hit && hit[:kind] == :wall
          @hover_wall = hit
        elsif hit && hit[:kind] == :unit && hit[:unit] != @moving_unit
          @hover_unit = hit[:unit]
          @hover_face = hit[:face]
        end
        recompute_preview(view)
      end

      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      hit = analyze_hover_target(view, x, y)

      # الخطوة 1: اختيار القطعة الأولى والجنب/الوجه المحدد عليها
      if @moving_unit.nil? || !@moving_unit.valid? || @source_face.nil?
        if hit && hit[:kind] == :unit
          @moving_unit = hit[:unit]
          @source_face = hit[:face]
          Sketchup.active_model.selection.clear
          Sketchup.active_model.selection.add(@moving_unit)
          update_status_prompt
          view.invalidate
        else
          Sketchup.status_text = '⚠️ من فضلك اضغط أولاً على جنب أو وش أو ظهر القطعة التي تريد تحريكها.'
        end
        return
      end

      # الخطوة 2: تنفيذ اللزق في المكان المحدد على الحائط أو على الوحدة الثانية
      target_info = nil
      if hit && hit[:kind] == :wall
        target_info = hit
      elsif hit && hit[:kind] == :unit && hit[:unit] != @moving_unit
        target_info = {
          :kind     => :unit,
          :unit     => hit[:unit],
          :face     => hit[:face],
          :normal   => hit[:face][:normal],
          :click_pt => hit[:face][:click_pt],
          :label    => hit[:face][:label]
        }
      end

      unless target_info
        # إذا ضغط المستخدم على وجه آخر في نفس القطعة الأولى نحدّث الوجه المختار
        ph = view.pick_helper
        ph.do_pick(x, y)
        ip = Sketchup::InputPoint.new
        ip.pick(view, x, y)
        (0...ph.count).each do |idx|
          path = ph.path_at(idx)
          next unless path && path.first == @moving_unit
          new_face = pick_unit_face_at(view, x, y, @moving_unit, ip.valid? ? ip.position : nil, path, ph.transformation_at(idx))
          if new_face
            @source_face = new_face
            update_status_prompt
            view.invalidate
            return
          end
        end
        return
      end

      res = compute_snap_transformation(@moving_unit, @source_face, target_info)
      return unless res && res[:transform]

      model = Sketchup.active_model
      model.start_operation('لزق ومحاذاة ذكي - مكتبة محمد عادل', true)
      begin
        @moving_unit.transform!(res[:transform])
      ensure
        model.commit_operation
      end

      @moving_unit       = nil
      @source_face       = nil
      @hover_unit        = nil
      @hover_face        = nil
      @hover_wall        = nil
      @preview_ghost_pts = nil
      Sketchup.status_text = "✅ تم اللزق والمحاذاة (#{res[:z_desc]}) بنجاح! اضغط على جنب قطعة جديدة أو Esc للخروج."
      view.invalidate
    end

    def draw_face_highlight(view, face_hash, fill_color, border_color, point_color)
      return unless face_hash && face_hash[:quad]
      q = face_hash[:quad]
      view.drawing_color = fill_color
      view.draw(GL_QUADS, q)
      view.line_width = 3
      view.drawing_color = border_color
      view.draw(GL_LINE_LOOP, q)
      if face_hash[:click_pt]
        view.draw_points([face_hash[:click_pt]], 12, 4, point_color)
      end
    end

    def draw(view)
      if @moving_unit && @moving_unit.valid? && @source_face
        draw_face_highlight(
          view,
          @source_face,
          Sketchup::Color.new(245, 200, 76, 85),
          Sketchup::Color.new(245, 200, 76, 255),
          Sketchup::Color.new(255, 255, 255, 255)
        )
      end

      if @hover_face
        draw_face_highlight(
          view,
          @hover_face,
          Sketchup::Color.new(56, 189, 248, 70),
          Sketchup::Color.new(56, 189, 248, 240),
          Sketchup::Color.new(245, 200, 76, 255)
        )
      elsif @hover_wall && @hover_wall[:click_pt]
        pt = @hover_wall[:click_pt]
        view.draw_points([pt], 14, 4, Sketchup::Color.new(245, 200, 76, 255))
      end

      if @preview_ghost_pts && @preview_ghost_pts.length == 8
        pts = @preview_ghost_pts
        edges = [0,1, 1,3, 3,2, 2,0, 4,5, 5,7, 7,6, 6,4, 0,4, 1,5, 2,6, 3,7]
        view.line_width = 3
        view.line_stipple = ''
        view.drawing_color = Sketchup::Color.new(74, 222, 128, 230)
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
  #  تحديث تلقائي لقائمة الدريسينج داخل المعرض (UI/index.html + نافذة المعرض الحية)
  #  لتغيير الـ CSS إلى الثيم الملكي الفاخر وتغيير المسميات إلى:
  #  - دريسينج عدل (أعلى)
  #  - دريسينج حرف L (أسفل)
  # ============================================================================
  GALLERY_DRESSING_LUXURY_CSS = <<~CSS.freeze
    .mode-switch-group {
      background: rgba(11, 17, 32, 0.78) !important;
      padding: 4px !important;
      border-radius: 11px !important;
      border: 1px solid rgba(245, 200, 76, 0.30) !important;
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.06) !important;
    }
    .mode-switch-btn {
      font-weight: 800 !important;
      font-size: 12.5px !important;
      border-radius: 8px !important;
      padding: 6px 16px !important;
    }
    .mode-switch-btn:hover {
      color: #fef3c7 !important;
      background: rgba(245, 200, 76, 0.10) !important;
    }
    .mode-switch-btn.active {
      background: linear-gradient(135deg, #f5c84c 0%, #d99b26 100%) !important;
      color: #0b1120 !important;
      box-shadow: 0 4px 14px rgba(245, 200, 76, 0.38) !important;
    }
    #dressingOverlayPanel {
      background: linear-gradient(165deg, rgba(11, 17, 32, 0.96) 0%, rgba(17, 26, 46, 0.95) 100%) !important;
      backdrop-filter: blur(20px) !important;
      -webkit-backdrop-filter: blur(20px) !important;
      border: 1px solid rgba(245, 200, 76, 0.34) !important;
      border-radius: 24px !important;
      box-shadow: 0 24px 64px rgba(0, 0, 0, 0.65), 0 0 0 1px rgba(255, 255, 255, 0.04) inset !important;
    }
    .dressingChoices {
      padding: 22px !important;
      gap: 18px !important;
    }
    .dressingChoice {
      border: 1px solid rgba(245, 200, 76, 0.22) !important;
      border-radius: 20px !important;
      background: radial-gradient(ellipse at 50% 22%, rgba(245, 200, 76, 0.13), transparent 62%), linear-gradient(160deg, #162238 0%, #0c1424 100%) !important;
      color: #f8fafc !important;
      box-shadow: 0 10px 28px rgba(0, 0, 0, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.06) !important;
      transition: border-color 0.24s ease, box-shadow 0.24s ease, transform 0.24s ease, background 0.24s ease !important;
    }
    .dressingChoice:hover {
      transform: translateY(-3px) !important;
      border-color: rgba(245, 200, 76, 0.82) !important;
      background: radial-gradient(ellipse at 50% 22%, rgba(245, 200, 76, 0.22), transparent 65%), linear-gradient(160deg, #1c2c48 0%, #101b30 100%) !important;
      box-shadow: 0 18px 40px rgba(0, 0, 0, 0.48), 0 0 28px rgba(245, 200, 76, 0.16), inset 0 0 34px rgba(245, 200, 76, 0.06) !important;
    }
    .dressingChoiceIcon {
      width: 104px !important;
      height: 104px !important;
      border: 1px solid rgba(245, 200, 76, 0.36) !important;
      border-radius: 26px !important;
      background: linear-gradient(145deg, rgba(245, 200, 76, 0.20), rgba(217, 155, 38, 0.08)) !important;
      color: #f5c84c !important;
      box-shadow: 0 12px 28px rgba(0, 0, 0, 0.30), inset 0 1px 0 rgba(255, 255, 255, 0.14) !important;
    }
    .dressingChoice:hover .dressingChoiceIcon {
      transform: translateY(-4px) scale(1.04) !important;
      border-color: #f5c84c !important;
      background: linear-gradient(145deg, rgba(245, 200, 76, 0.32), rgba(217, 155, 38, 0.16)) !important;
      color: #fde68a !important;
      box-shadow: 0 14px 32px rgba(245, 200, 76, 0.24) !important;
    }
    .dressingChoiceTitle {
      font-size: 25px !important;
      font-weight: 800 !important;
      color: #fef3c7 !important;
      text-shadow: 0 2px 10px rgba(0, 0, 0, 0.35) !important;
    }
    .dressingChoiceDesc {
      font-size: 13.5px !important;
      font-weight: 600 !important;
      color: #94a3b8 !important;
    }
    .embeddedLoadingCard {
      border: 1px solid rgba(245, 200, 76, 0.42) !important;
      border-radius: 20px !important;
      background: linear-gradient(160deg, #111a2e 0%, #0b1120 100%) !important;
    }
    .embeddedLoadingBrand { color: #f5c84c !important; }
    .embeddedLoadingTrack { border-color: rgba(245, 200, 76, 0.45) !important; background: #090d16 !important; }
    .embeddedLoadingFill { background: linear-gradient(90deg, #d99b26, #f5c84c) !important; box-shadow: 0 0 14px rgba(245, 200, 76, 0.55) !important; }
    .embeddedLoadingPercent { color: #f5c84c !important; font-weight: 800 !important; }
  CSS

  def self.inject_gallery_dressing_ui_into_dialog(dlg = nil)
    target_dlg = dlg || (instance_variable_defined?(:@dlg) ? @dlg : nil)
    return unless target_dlg && target_dlg.visible?
    css_json = JSON.generate(GALLERY_DRESSING_LUXURY_CSS)
    js = <<~JS
      (function(){
        var st = document.getElementById('dolaLuxuryDressingStyle');
        if (!st) {
          st = document.createElement('style');
          st.id = 'dolaLuxuryDressingStyle';
          document.head.appendChild(st);
        }
        st.textContent = #{css_json};
        var dBtn = document.getElementById('dressingModeBtn');
        if (dBtn) dBtn.textContent = 'دريسينج';
        var choices = document.querySelectorAll('#dressingOverlayPanel .dressingChoice');
        if (choices.length >= 1) {
          var t1 = choices[0].querySelector('.dressingChoiceTitle');
          var d1 = choices[0].querySelector('.dressingChoiceDesc');
          if (t1) t1.textContent = 'دريسينج عدل';
          if (d1) d1.textContent = 'تصميم وحدة دريسينج عدل بتقسيمات مرنة واحترافية';
        }
        if (choices.length >= 2) {
          var t2 = choices[1].querySelector('.dressingChoiceTitle');
          var d2 = choices[1].querySelector('.dressingChoiceDesc');
          if (t2) t2.textContent = 'دريسينج حرف L';
          if (d2) d2.textContent = 'تصميم وحدة دريسينج حرف L لاستغلال المساحة والركنة';
        }
      })();
    JS
    target_dlg.execute_script(js) rescue nil
  rescue
    nil
  end

  def self.patch_local_gallery_index_html!
    base_dirs = []
    base_dirs << CURRENT_DIR if const_defined?(:CURRENT_DIR) && CURRENT_DIR
    base_dirs << File.dirname(__FILE__) rescue nil
    base_dirs.compact.uniq.each do |bdir|
      ['UI', 'ui'].each do |sub|
        idx_path = File.join(bdir, sub, 'index.html')
        next unless File.exist?(idx_path)
        content = File.open(idx_path, 'rb:UTF-8') { |f| f.read } rescue nil
        next unless content
        modified = false

        if content.include?('<span class="dressingChoiceTitle">مستقيم</span>')
          content = content.gsub('<span class="dressingChoiceTitle">مستقيم</span>', '<span class="dressingChoiceTitle">دريسينج عدل</span>')
          content = content.gsub('وحدة دريسنج مستقيمة بتقسيمات مرنة', 'تصميم وحدة دريسينج عدل بتقسيمات مرنة واحترافية')
          modified = true
        end
        if content.include?('<span class="dressingChoiceTitle">زاوية</span>')
          content = content.gsub('<span class="dressingChoiceTitle">زاوية</span>', '<span class="dressingChoiceTitle">دريسينج حرف L</span>')
          content = content.gsub('وحدة دريسنج زاوية لاستغلال المساحة', 'تصميم وحدة دريسينج حرف L لاستغلال المساحة والركنة')
          modified = true
        end
        if content.include?(">دريسنج</button>")
          content = content.gsub(">دريسنج</button>", ">دريسينج</button>")
          modified = true
        end
        unless content.include?('dolaLuxuryDressingStyle')
          style_tag = "\n    <style id=\"dolaLuxuryDressingStyle\">\n#{GALLERY_DRESSING_LUXURY_CSS}\n    </style>\n</head>"
          if content.include?('</head>')
            content = content.sub('</head>', style_tag)
            modified = true
          end
        end

        if modified
          File.open(idx_path, 'wb:UTF-8') { |f| f.write(content) } rescue nil
        end
      end
    end
  rescue
    nil
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

  # تحديث ملف الواجهة UI/index.html وحقن التعديلات في المعرض تلقائياً عند تحميل core.rb
  patch_local_gallery_index_html!
  UI.start_timer(0.5, false) { inject_gallery_dressing_ui_into_dialog }

end

MHDESIGN = DolaSmartLibraryPlugin unless Object.const_defined?(:MHDESIGN)