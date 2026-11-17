#!/usr/bin/env python3
"""Generate drawdb.lang for the TOS App Center (26 locales, English fill)."""
NAME_EN = "DrawDB ER Diagram Editor"
AUTHOR = "ericbyz"
DESC_EN = (
    "Database entity-relationship diagram editor: design ER diagrams visually, "
    "export SQL for MySQL/PostgreSQL/SQLite/MariaDB/MSSQL and more, import DBML, "
    "and generate diagrams from existing schemas. Pure static app served by the "
    "TOS web server (no background service, no extra port). Built from upstream "
    "drawdb-io/drawdb v1.9.0 (AGPL-3.0) with all assets bundled locally "
    "(intranet-safe)."
)
NOTE_EN = "1. Built from upstream drawdb-io/drawdb (AGPL-3.0) at a pinned commit for TOS."
NOTE_ZH = "1. 基于上游 drawdb-io/drawdb(AGPL-3.0)锁定 commit 构建并封装为 TOS 应用。"

PRIMARY = [
    ("zh-cn", "DrawDB 数据库 ER 图设计器",
     "可视化设计数据库 ER 图:拖拽建表、定义字段与关系,一键导出 MySQL/PostgreSQL/"
     "SQLite/MariaDB/MSSQL 等 SQL,支持 DBML 导入导出。纯静态应用(无后台服务、不占端口),"
     "由 TOS 网页服务直接托管,悬浮窗内直接使用。基于上游 v1.9.0 锁定 commit 构建"
     "(AGPL-3.0),monaco 编辑器与图标字体全部本地化,内网环境开箱即用。"),
    ("zh-hk", "DrawDB 數據庫 ER 圖設計器",
     "可視化設計數據庫 ER 圖:拖拽建表、定義字段與關係,一鍵導出 MySQL/PostgreSQL/"
     "SQLite/MariaDB/MSSQL 等 SQL,支持 DBML 導入導出。純靜態應用(無後台服務、不佔端口)。"),
]

ORDER = ["zh-cn", "zh-hk", "en-us", "ko-kr", "ja-jp", "de-de", "fr-fr", "it-it",
         "es-es", "hu-hu", "pl-pl", "tr-tr", "ru-ru", "pt-pt", "cs-cz", "da-dk",
         "nl-nl", "nb-no", "sv-se", "el-gr", "ro-ro", "th-th", "vi-vn", "id-id",
         "ar-sa", "he-il"]

NATIVE = {
    "ja-jp": "データベース ER 図エディタ:テーブルをドラッグで作成し、フィールドとリレーションを定義、MySQL/PostgreSQL/SQLite などへ SQL を出力、DBML 対応。バックグラウンドサービス不要の純静的アプリで TOS の Web サーバーから配信。上流 v1.9.0 を固定コミットでビルド(AGPL-3.0)、全アセットローカル配信。",
    "ko-kr": "데이터베이스 ER 다이어그램 편집기: 테이블을 드래그로 만들고 필드·관계를 정의하며 MySQL/PostgreSQL/SQLite 등으로 SQL을 내보내고 DBML을 지원합니다. 백그라운드 서비스가 없는 순정적 앱. 업스트림 v1.9.0 고정 커밋 빌드(AGPL-3.0), 모든 에셋 로컬 제공.",
    "de-de": "Datenbank-ER-Diagramm-Editor: Tabellen per Drag-and-drop erstellen, Felder und Beziehungen definieren, SQL für MySQL/PostgreSQL/SQLite u.v.m. exportieren, DBML-Import. Rein statische App ohne Hintergrunddienst, vom TOS-Webserver ausgeliefert. Gebaut aus Upstream v1.9.0 (AGPL-3.0), alle Assets lokal.",
    "fr-fr": "Éditeur de diagrammes ER de bases de données : créez des tables par glisser-déposer, définissez champs et relations, exportez du SQL (MySQL/PostgreSQL/SQLite etc.), importez du DBML. Application purement statique servie par le serveur web TOS. Construite depuis l'amont v1.9.0 (AGPL-3.0), ressources 100 % locales.",
    "es-es": "Editor de diagramas ER de bases de datos: cree tablas arrastrando, defina campos y relaciones, exporte SQL para MySQL/PostgreSQL/SQLite etc. e importe DBML. Aplicación puramente estática servida por el servidor web de TOS. Construida desde el upstream v1.9.0 (AGPL-3.0), recursos locales.",
    "ru-ru": "Редактор ER-диаграмм баз данных: создавайте таблицы перетаскиванием, задавайте поля и связи, экспортируйте SQL для MySQL/PostgreSQL/SQLite и др., поддерживается DBML. Чисто статическое приложение без фоновой службы. Собрано из upstream v1.9.0 (AGPL-3.0), все ресурсы локальные.",
}

def main(out_path):
    lines = []
    for loc in ORDER:
        name, desc = NAME_EN, NATIVE.get(loc, DESC_EN)
        for l, n, d in PRIMARY:
            if l == loc:
                name, desc = n, d
                break
        note = NOTE_ZH if loc in ("zh-cn", "zh-hk") else NOTE_EN
        lines += [f"[{loc}]", f'name = "{name}"', f'auth = "{AUTHOR}"',
                  f'descript = "{desc}"', f'note = "{note}"', ""]
    open(out_path, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
    print("wrote", out_path, len(ORDER), "locales")

if __name__ == "__main__":
    main("drawdb.lang")
