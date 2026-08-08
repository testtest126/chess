/* ==========================================================================
   THE FLEET — language tables
   --------------------------------------------------------------------------
   Adding a language means adding one entry to LANGS and one code to ORDER.
   Nothing else in the codebase needs to change.

   Scope, stated honestly: these tables cover the INTERFACE — the switchers,
   their menus, the accessibility theme names, the assistive-technology
   labels. They do not cover the chapters themselves. The fleet story is long
   literary prose, and a machine pass over it would be worse than useless
   dressed up as finished work, so every chapter body is still English and
   says so, in the reader's own language, via `proseNote`.

   When a real chapter translation does arrive it drops into PROSE below,
   keyed by language and page id; `hasProse()` then stops showing the note
   for that page. The machinery is already wired — only the text is missing.

   A note on `lang`: the <html> element takes the selected language so the UI
   is announced correctly, but any chapter whose prose is still English is
   marked lang="en" dir="ltr" by fleet.js. Claiming Arabic on English prose
   would make a screen reader read English words with Arabic phonetics — the
   opposite of accessible.
   ========================================================================== */

(function () {
  "use strict";

  /* Every string an interface element can need. Sixteen keys, kept short on
     purpose: short strings are the ones that survive translation intact. */
  var LANGS = {

    en: {
      name: "English", dir: "ltr",
      langLabel: "Language", langMenu: "Choose language",
      themeLabel: "Theme", themeMenu: "Visual theme",
      groupAccess: "Accessibility", groupPalette: "Palettes",
      themeDefault: "Default",
      themeContrast: "High contrast",
      themeColorblind: "Colour-blind safe",
      themeDyslexia: "Dyslexia-friendly",
      readingProgress: "Reading progress",
      proseNote: "Chapter prose: English (translation in progress)",
      uiNote: "Interface translated"
    },

    uk: {
      name: "Українська", dir: "ltr",
      langLabel: "Мова", langMenu: "Вибрати мову",
      themeLabel: "Тема", themeMenu: "Візуальна тема",
      groupAccess: "Доступність", groupPalette: "Палітри",
      themeDefault: "Стандартна",
      themeContrast: "Високий контраст",
      themeColorblind: "Безпечна для дальтоніків",
      themeDyslexia: "Зручна для дислексії",
      readingProgress: "Прогрес читання",
      proseNote: "Текст розділу — англійською (переклад триває)",
      uiNote: "Інтерфейс перекладено"
    },

    es: {
      name: "Español", dir: "ltr",
      langLabel: "Idioma", langMenu: "Elegir idioma",
      themeLabel: "Tema", themeMenu: "Tema visual",
      groupAccess: "Accesibilidad", groupPalette: "Paletas",
      themeDefault: "Predeterminado",
      themeContrast: "Alto contraste",
      themeColorblind: "Apto para daltonismo",
      themeDyslexia: "Apto para dislexia",
      readingProgress: "Progreso de lectura",
      proseNote: "Texto del capítulo: en inglés (traducción en curso)",
      uiNote: "Interfaz traducida"
    },

    "zh-Hans": {
      name: "简体中文", dir: "ltr",
      langLabel: "语言", langMenu: "选择语言",
      themeLabel: "主题", themeMenu: "视觉主题",
      groupAccess: "无障碍", groupPalette: "配色",
      themeDefault: "默认",
      themeContrast: "高对比度",
      themeColorblind: "色盲友好",
      themeDyslexia: "阅读障碍友好",
      readingProgress: "阅读进度",
      proseNote: "章节正文：英文（翻译进行中）",
      uiNote: "界面已翻译"
    },

    hi: {
      name: "हिन्दी", dir: "ltr",
      langLabel: "भाषा", langMenu: "भाषा चुनें",
      themeLabel: "थीम", themeMenu: "दृश्य थीम",
      groupAccess: "सुगम्यता", groupPalette: "रंग-पट्टिकाएँ",
      themeDefault: "डिफ़ॉल्ट",
      themeContrast: "उच्च कंट्रास्ट",
      themeColorblind: "वर्णांधता-अनुकूल",
      themeDyslexia: "डिस्लेक्सिया-अनुकूल",
      readingProgress: "पढ़ने की प्रगति",
      proseNote: "अध्याय का पाठ: अंग्रेज़ी में (अनुवाद जारी है)",
      uiNote: "इंटरफ़ेस अनूदित"
    },

    ar: {
      name: "العربية", dir: "rtl",
      langLabel: "اللغة", langMenu: "اختر اللغة",
      themeLabel: "المظهر", themeMenu: "المظهر المرئي",
      groupAccess: "إمكانية الوصول", groupPalette: "لوحات الألوان",
      themeDefault: "الافتراضي",
      themeContrast: "تباين عالٍ",
      themeColorblind: "مناسب لعمى الألوان",
      themeDyslexia: "مناسب لعسر القراءة",
      readingProgress: "تقدّم القراءة",
      proseNote: "نص الفصل: بالإنجليزية (الترجمة قيد العمل)",
      uiNote: "تمت ترجمة الواجهة"
    },

    he: {
      name: "עברית", dir: "rtl",
      langLabel: "שפה", langMenu: "בחירת שפה",
      themeLabel: "ערכת נושא", themeMenu: "ערכת נושא חזותית",
      groupAccess: "נגישות", groupPalette: "לוחות צבעים",
      themeDefault: "ברירת מחדל",
      themeContrast: "ניגודיות גבוהה",
      themeColorblind: "ידידותי לעיוורון צבעים",
      themeDyslexia: "ידידותי לדיסלקציה",
      readingProgress: "התקדמות קריאה",
      proseNote: "טקסט הפרק: באנגלית (התרגום בעבודה)",
      uiNote: "הממשק תורגם"
    },

    fa: {
      name: "فارسی", dir: "rtl",
      langLabel: "زبان", langMenu: "انتخاب زبان",
      themeLabel: "پوسته", themeMenu: "پوستهٔ ظاهری",
      groupAccess: "دسترس‌پذیری", groupPalette: "پالت‌ها",
      themeDefault: "پیش‌فرض",
      themeContrast: "کنتراست بالا",
      themeColorblind: "مناسب کوررنگی",
      themeDyslexia: "مناسب نارساخوانی",
      readingProgress: "پیشرفت مطالعه",
      proseNote: "متن فصل: به انگلیسی (ترجمه در حال انجام)",
      uiNote: "رابط کاربری ترجمه شد"
    },

    fr: {
      name: "Français", dir: "ltr",
      langLabel: "Langue", langMenu: "Choisir la langue",
      themeLabel: "Thème", themeMenu: "Thème visuel",
      groupAccess: "Accessibilité", groupPalette: "Palettes",
      themeDefault: "Par défaut",
      themeContrast: "Contraste élevé",
      themeColorblind: "Adapté au daltonisme",
      themeDyslexia: "Adapté à la dyslexie",
      readingProgress: "Progression de lecture",
      proseNote: "Texte du chapitre : en anglais (traduction en cours)",
      uiNote: "Interface traduite"
    },

    pt: {
      name: "Português", dir: "ltr",
      langLabel: "Idioma", langMenu: "Escolher idioma",
      themeLabel: "Tema", themeMenu: "Tema visual",
      groupAccess: "Acessibilidade", groupPalette: "Paletas",
      themeDefault: "Padrão",
      themeContrast: "Alto contraste",
      themeColorblind: "Seguro para daltonismo",
      themeDyslexia: "Amigável à dislexia",
      readingProgress: "Progresso de leitura",
      proseNote: "Texto do capítulo: em inglês (tradução em andamento)",
      uiNote: "Interface traduzida"
    },

    bn: {
      name: "বাংলা", dir: "ltr",
      langLabel: "ভাষা", langMenu: "ভাষা নির্বাচন করুন",
      themeLabel: "থিম", themeMenu: "ভিজ্যুয়াল থিম",
      groupAccess: "অ্যাক্সেসিবিলিটি", groupPalette: "রঙের প্যালেট",
      themeDefault: "ডিফল্ট",
      themeContrast: "উচ্চ কনট্রাস্ট",
      themeColorblind: "বর্ণান্ধতা-বান্ধব",
      themeDyslexia: "ডিসলেক্সিয়া-বান্ধব",
      readingProgress: "পড়ার অগ্রগতি",
      proseNote: "অধ্যায়ের লেখা: ইংরেজিতে (অনুবাদ চলছে)",
      uiNote: "ইন্টারফেস অনূদিত"
    },

    ja: {
      name: "日本語", dir: "ltr",
      langLabel: "言語", langMenu: "言語を選択",
      themeLabel: "テーマ", themeMenu: "表示テーマ",
      groupAccess: "アクセシビリティ", groupPalette: "パレット",
      themeDefault: "デフォルト",
      themeContrast: "ハイコントラスト",
      themeColorblind: "色覚サポート",
      themeDyslexia: "ディスレクシア対応",
      readingProgress: "読書の進捗",
      proseNote: "本文は英語のままです（翻訳作業中）",
      uiNote: "インターフェース翻訳済み"
    },

    de: {
      name: "Deutsch", dir: "ltr",
      langLabel: "Sprache", langMenu: "Sprache wählen",
      themeLabel: "Design", themeMenu: "Visuelles Design",
      groupAccess: "Barrierefreiheit", groupPalette: "Paletten",
      themeDefault: "Standard",
      themeContrast: "Hoher Kontrast",
      themeColorblind: "Farbenblind-sicher",
      themeDyslexia: "Legasthenie-freundlich",
      readingProgress: "Lesefortschritt",
      proseNote: "Kapiteltext: auf Englisch (Übersetzung in Arbeit)",
      uiNote: "Oberfläche übersetzt"
    },

    sw: {
      name: "Kiswahili", dir: "ltr",
      langLabel: "Lugha", langMenu: "Chagua lugha",
      themeLabel: "Mandhari", themeMenu: "Mandhari ya kuona",
      groupAccess: "Ufikivu", groupPalette: "Paleti",
      themeDefault: "Chaguo-msingi",
      themeContrast: "Utofautishaji mkubwa",
      themeColorblind: "Rafiki kwa upofu wa rangi",
      themeDyslexia: "Rafiki kwa dyslexia",
      readingProgress: "Maendeleo ya kusoma",
      proseNote: "Maandishi ya sura: kwa Kiingereza (tafsiri inaendelea)",
      uiNote: "Kiolesura kimetafsiriwa"
    },

    /* Two smaller languages, included because a story about many voices
       sharing one signature should be readable in more than the largest
       markets. Both are living, actively revitalised languages. */
    mi: {
      name: "Te Reo Māori", dir: "ltr",
      langLabel: "Reo", langMenu: "Kōwhiria te reo",
      themeLabel: "Kāhua", themeMenu: "Kāhua ataata",
      groupAccess: "Whakaurunga", groupPalette: "Papatae tae",
      themeDefault: "Taunoa",
      themeContrast: "Pūrangiaho nui",
      themeColorblind: "Haumaru karekare tae",
      themeDyslexia: "Pai ki te pānui uaua",
      readingProgress: "Ahunga pānui",
      proseNote: "Te tuhinga o te upoko: kei te reo Ingarihi (kei te whakamāoritia tonu)",
      uiNote: "Kua whakamāoritia te atanga"
    },

    qu: {
      name: "Runa Simi", dir: "ltr",
      langLabel: "Simi", langMenu: "Simita akllay",
      themeLabel: "Rikch'ay", themeMenu: "Rikuy rikch'ay",
      groupAccess: "Chayana atiy", groupPalette: "Llimp'i wakichiy",
      themeDefault: "Kikin",
      themeContrast: "Sinchi rikuy",
      themeColorblind: "Llimp'i mana rikuqpaq",
      themeDyslexia: "Ñawinchay sasachaypaq",
      readingProgress: "Ñawinchay puriynin",
      proseNote: "Yachana qillqa: inlis simipi (t'ikray ruwakuchkan)",
      uiNote: "Antawa t'ikrasqa"
    }
  };

  /* Menu order: English first, then by number of speakers, with the two
     smaller languages last so they read as a deliberate inclusion rather
     than as an afterthought buried mid-list. */
  var ORDER = ["en", "zh-Hans", "hi", "es", "fr", "ar", "bn", "pt", "uk",
               "ja", "de", "sw", "fa", "he", "mi", "qu"];

  /* Chapter prose translations, keyed by language then page id.
     Empty on purpose: no chapter has a translation good enough to ship yet.
     A finished chapter lands here as
         PROSE["uk"] = { "night-one": { ".standfirst": "…", … } };
     and the honest note stops appearing for that page automatically. */
  var PROSE = {};

  window.FleetI18n = {
    langs: LANGS,
    order: ORDER,
    prose: PROSE,
    fallback: "en",

    get: function (code) {
      return LANGS[code] || LANGS.en;
    },
    /* does this language have real, human prose for this page? */
    hasProse: function (code, pageId) {
      return !!(PROSE[code] && PROSE[code][pageId]);
    },
    /* best match for a browser tag such as "uk-UA" or "zh-Hans-CN" */
    resolve: function (tag) {
      if (!tag) return null;
      if (LANGS[tag]) return tag;
      var lower = String(tag).toLowerCase();
      for (var i = 0; i < ORDER.length; i++) {
        var code = ORDER[i];
        if (lower === code.toLowerCase()) return code;
      }
      var base = lower.split("-")[0];
      if (base === "zh") return "zh-Hans";
      for (var j = 0; j < ORDER.length; j++) {
        if (ORDER[j].toLowerCase().split("-")[0] === base) return ORDER[j];
      }
      return null;
    }
  };
})();
