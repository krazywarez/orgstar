import Foundation

/// Org's translations of what exporters and clock tables write (ox.el `org-export-dictionary`,
/// org-clock.el `org-clock-clocktable-language-setup`, Org 9.8.7), for `#+LANGUAGE` and
/// `org-export-default-language`.
public enum ExportDictionary {
    public enum Encoding: String, Sendable { case html, ascii, utf8 = "utf-8", latex }

    /// `org-export-translate`: the encoding's translation, else the language's default, else `term`.
    public static func translate(_ term: String, language: String, encoding: Encoding) -> String {
        guard let translations = dictionary[term]?[language] else { return term }
        return translations[encoding.rawValue] ?? translations["default"] ?? term
    }

    /// `org-clock--translate`: `term` among File, L, Timestamp, Headline, Time, ALL, Total time,
    /// File time and Clock summary at; the language is matched ignoring case.
    public static func clockTable(_ term: String, language: String) -> String {
        let terms = ["File", "L", "Timestamp", "Headline", "Time", "ALL", "Total time", "File time", "Clock summary at"]
        guard let index = terms.firstIndex(of: term),
              let row = clockTable.first(where: { $0.key.caseInsensitiveCompare(language) == .orderedSame })?.value,
              index < row.count else { return term }
        return row[index]
    }

    static let dictionary: [String: [String: [String: String]]] = [
        "Table of Contents": [
            "ar": ["default": "قائمة المحتويات"],
            "ca": ["html": "&Iacute;ndex"],
            "cs": ["default": "Obsah"],
            "da": ["default": "Indhold"],
            "de": ["default": "Inhaltsverzeichnis"],
            "eo": ["default": "Enhavo"],
            "es": ["ascii": "Indice", "html": "&Iacute;ndice", "default": "Índice"],
            "et": ["default": "Sisukord"],
            "fa": ["default": "فهرست"],
            "fi": ["html": "Sis&auml;llysluettelo"],
            "fr": ["ascii": "Sommaire", "default": "Table des matières"],
            "hu": ["html": "Tartalomjegyz&eacute;k"],
            "is": ["default": "Efnisyfirlit"],
            "it": ["default": "Indice"],
            "ja": ["default": "目次", "html": "&#30446;&#27425;"],
            "nl": ["default": "Inhoudsopgave"],
            "no": ["default": "Innhold"],
            "nb": ["default": "Innhold"],
            "nn": ["default": "Innhald"],
            "pl": ["default": "Spis treści", "html": "Spis tre&#x015b;ci"],
            "pt_BR": ["html": "&Iacute;ndice", "utf-8": "Índice", "ascii": "Indice"],
            "ro": ["default": "Cuprins"],
            "ru": ["html": "&#1057;&#1086;&#1076;&#1077;&#1088;&#1078;&#1072;&#1085;&#1080;&#1077;", "utf-8": "Содержание"],
            "sl": ["default": "Kazalo"],
            "sv": ["default": "Innehåll"],
            "tr": ["default": "İçindekiler"],
            "uk": ["html": "&#1047;&#1084;&#1110;&#1089;&#1090;", "utf-8": "Зміст"],
            "zh-CN": ["html": "&#30446;&#24405;", "utf-8": "目录"],
            "zh-TW": ["html": "&#30446;&#37636;", "utf-8": "目錄"],
        ],
        "Figure %d:": [
            "ar": ["default": "شكل %d:"],
            "cs": ["default": "Obrázek %d:"],
            "da": ["default": "Figur %d:"],
            "de": ["default": "Abbildung %d:"],
            "es": ["default": "Figura %d:"],
            "et": ["default": "Joonis %d:"],
            "fa": ["default": "شکل %d:"],
            "fr": ["default": "Figure %d:", "html": "Figure&nbsp;%d&nbsp;:"],
            "is": ["default": "Mynd %d:"],
            "it": ["default": "Figura %d:"],
            "ja": ["default": "図%d:", "html": "&#22259;%d:"],
            "nl": ["default": "Figuur %d:", "html": "Figuur&nbsp;%d:"],
            "no": ["default": "Illustrasjon %d:"],
            "nb": ["default": "Illustrasjon %d:"],
            "nn": ["default": "Illustrasjon %d:"],
            "pl": ["default": "Obrazek %d:"],
            "pt_BR": ["default": "Figura %d:"],
            "ro": ["default": "Imaginea %d:"],
            "ru": ["html": "&#1056;&#1080;&#1089;. %d.:", "utf-8": "Рис. %d.:"],
            "sl": ["default": "Slika %d:"],
            "sv": ["default": "Illustration %d:"],
            "tr": ["default": "Şekil %d:"],
            "zh-CN": ["html": "&#22270;%d&nbsp;", "utf-8": "图%d "],
        ],
        "Footnotes": [
            "ar": ["default": "الهوامش"],
            "ca": ["html": "Peus de p&agrave;gina"],
            "cs": ["default": "Poznámky pod čarou"],
            "da": ["default": "Fodnoter"],
            "de": ["html": "Fu&szlig;noten", "default": "Fußnoten"],
            "eo": ["default": "Piednotoj"],
            "es": ["ascii": "Notas al pie de pagina", "html": "Notas al pie de p&aacute;gina", "default": "Notas al pie de página"],
            "et": ["default": "Allmärkused", "html": "Allm&#228;rkused", "utf-8": "Allmärkused"],
            "fa": ["default": "پانوشت‌ها"],
            "fi": ["default": "Alaviitteet"],
            "fr": ["default": "Notes de bas de page"],
            "hu": ["html": "L&aacute;bjegyzet"],
            "is": ["html": "Aftanm&aacute;lsgreinar"],
            "it": ["html": "Note a pi&egrave; di pagina"],
            "ja": ["default": "脚注", "html": "&#33050;&#27880;"],
            "nl": ["default": "Voetnoten"],
            "no": ["default": "Fotnoter"],
            "nb": ["default": "Fotnoter"],
            "nn": ["default": "Fotnotar"],
            "pl": ["default": "Przypis"],
            "pt_BR": ["html": "Notas de Rodap&eacute;", "default": "Notas de Rodapé", "ascii": "Notas de Rodape"],
            "ro": ["default": "Note de subsol"],
            "ru": ["html": "&#1057;&#1085;&#1086;&#1089;&#1082;&#1080;", "utf-8": "Сноски"],
            "sl": ["default": "Opombe"],
            "sv": ["default": "Fotnoter"],
            "tr": ["default": "Dipnotlar"],
            "uk": ["html": "&#1055;&#1088;&#1080;&#1084;&#1110;&#1090;&#1082;&#1080;", "utf-8": "Примітки"],
            "zh-CN": ["html": "&#33050;&#27880;", "utf-8": "脚注"],
            "zh-TW": ["html": "&#33139;&#35387;", "utf-8": "腳註"],
        ],
    ]

    static let clockTable: [String: [String]] = [
        "en": ["File", "L", "Timestamp", "Headline", "Time", "ALL", "Total time", "File time", "Clock summary at"],
        "de": ["Datei", "E", "Zeitstempel", "Kopfzeile", "Dauer", "GESAMT", "Gesamtdauer", "Dateizeit", "Erstellt am"],
        "es": ["Archivo", "N", "Fecha y hora", "Tarea", "Duración", "TODO", "Duración total", "Tiempo archivo", "Generado el"],
        "fr": ["Fichier", "N", "Horodatage", "En-tête", "Durée", "TOUT", "Durée totale", "Durée fichier", "Horodatage sommaire à"],
        "nl": ["Bestand", "N", "Tijdstip", "Rubriek", "Duur", "ALLES", "Totale duur", "Bestandstijd", "Klok overzicht op"],
        "nn": ["Fil", "N", "Tidspunkt", "Overskrift", "Tid", "ALLE", "Total tid", "Filtid", "Tidsoversyn"],
        "pl": ["Plik", "P", "Data i godzina", "Nagłówek", "Czas", "WSZYSTKO", "Czas całkowity", "Czas pliku", "Poddumowanie zegara na"],
        "pt-BR": ["Arquivo", "N", "Data e hora", "Título", "Hora", "TODOS", "Hora total", "Hora do arquivo", "Resumo das horas em"],
        "sk": ["Súbor", "L", "Časová značka", "Záhlavie", "Čas", "VŠETKO", "Celkový čas", "Čas súboru", "Časový súhrn pre"],
    ]
}
