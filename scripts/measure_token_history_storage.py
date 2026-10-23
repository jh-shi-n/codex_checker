"""일별 집계의 실제 SQLite 스키마 기준 기간·계정 수별 파일 용량 측정."""
import calendar
import datetime as dt
import json
import pathlib
import sqlite3
import tempfile


def cutoff(reference, months):
    """월말 보정을 포함한 달력 개월 수 이전 날짜 반환."""
    month = reference.year * 12 + reference.month - 1 - months
    year, month = divmod(month, 12)
    return reference.replace(year=year, month=month + 1,
                             day=min(reference.day, calendar.monthrange(year, month + 1)[1]))


def measure(schema, reference, months, accounts, maximum):
    """동일 스키마·4096바이트 페이지의 실제 DB 생성 및 완료 파일 크기 반환."""
    with tempfile.TemporaryDirectory(prefix="token-history-size-") as folder:
        path = pathlib.Path(folder) / "history.sqlite"
        database = sqlite3.connect(path)
        database.execute("PRAGMA page_size = 4096")
        database.execute("PRAGMA auto_vacuum = INCREMENTAL")
        database.executescript(schema)
        first = cutoff(reference, months)
        days = (reference - first).days + 1
        for index in range(accounts):
            account = f"C{index + 1}"
            database.execute("INSERT INTO token_history_accounts VALUES (?, ?, ?)",
                             (account, f"/Users/example/accounts/{account}/.codex", 1792713600.123456))
            for offset in range(days):
                values = (2**63 - 1,) * 4 if maximum else (12_345_678, 1_234_567, 7_654_321, 42)
                database.execute("INSERT INTO token_daily_history VALUES (?, ?, ?, ?, ?, ?, ?)",
                                 (account, (first + dt.timedelta(days=offset)).isoformat(), *values, 1792713600.123456))
        database.commit()
        pages = database.execute("PRAGMA page_count").fetchone()[0]
        database.close()
        return dict(months=months, accounts=accounts, days=days, rows=accounts * days,
                    scenario="int64_max" if maximum else "typical", bytes=path.stat().st_size,
                    kib=path.stat().st_size / 1024, pages=pages)


def main():
    """고정 기준일과 구현 공용 스키마를 사용한 측정 결과의 JSON 출력."""
    schema = (pathlib.Path(__file__).resolve().parents[1] /
              "Sources/CodexQuotaMonitorKit/Resources/token-history-schema.sql").read_text()
    reference = dt.date(2026, 10, 23)
    results = [measure(schema, reference, months, accounts, maximum)
               for accounts in (1, 4) for maximum in (False, True) for months in (3, 6, 12)]
    print(json.dumps(dict(reference=reference.isoformat(), measurements=results), indent=2))


if __name__ == "__main__":
    main()
