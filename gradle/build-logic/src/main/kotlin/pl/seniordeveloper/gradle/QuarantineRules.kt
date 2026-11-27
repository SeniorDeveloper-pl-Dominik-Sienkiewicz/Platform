package pl.seniordeveloper.gradle

import java.time.LocalDate

/** Jedno oznaczenie kwarantanny w źródłach testów i to, co bramka o nim sądzi. */
data class QuarantineEntry(
	val file: String,
	val line: Int,
	val issue: String?,
	val until: LocalDate?,
)

/**
 * Kwarantanna z terminem (N-REL-13): każde oznaczenie testu tagiem `quarantine` wymaga w trzech liniach nad sobą
 * komentarza `// quarantine: <issue-url> until YYYY-MM-DD`, więc kwarantanna nie zamienia się w cmentarz testów.
 * Oznaczenie to `@Tag("quarantine")`, `@Tag(value = …)` albo stała `QUARANTINE` (także po imporcie statycznym)
 * oraz użycie meta-adnotacji zadeklarowanej w skanowanych źródłach, która niesie tag (także pośrednio). Sama
 * deklaracja meta-adnotacji komentarza nie wymaga — wymaga go każde jej użycie. Poza zasięgiem skanu tekstowego:
 * stała o innej nazwie z tą samą wartością i meta-adnotacja spoza skanowanych źródeł (docs/gates.md, PLAT-QUA-001).
 * Brak komentarza failuje zawsze, przeterminowany wpis — tylko w CI (Decyzja owner'a: stare commity zostają
 * odtwarzalne lokalnie).
 */
object QuarantineRules {
	private val TAG = Regex("""@Tag\s*\(\s*(?:value\s*=\s*)?(?:"quarantine"|(?:[\w.]+\.)?QUARANTINE)\s*\)""")
	private val COMMENT = Regex("""//\s*quarantine:\s*(\S+)\s+until\s+(\d{4}-\d{2}-\d{2})""")
	private val DECLARATION = Regex("""@interface\b|\b(?:class|interface|fun|void|record|enum|object)\b""")
	private val ANNOTATION_DECLARATION = Regex("""(?:@interface|\bannotation\s+class)\s+(\w+)""")
	private const val DECLARATION_LOOKAHEAD = 10

	/** Skanuje wszystkie źródła razem, bo meta-adnotacja z jednego pliku kwarantannuje testy w innych. */
	fun scan(files: List<Pair<String, String>>): List<QuarantineEntry> {
		val sources = files.map { (file, text) -> file to text.lines() }
		val markers = quarantineMarkers(sources)
		return sources.flatMap { (file, lines) ->
			lines.indices
				.filter { index -> markers.any { it.containsMatchIn(lines[index]) } && declaredAnnotation(lines, index) == null }
				.map { index -> entry(file, lines, index) }
		}
	}

	private fun quarantineMarkers(sources: List<Pair<String, List<String>>>): List<Regex> {
		val markers = mutableListOf(TAG)
		val annotations = mutableSetOf<String>()
		do {
			val found =
				sources
					.flatMap { (_, lines) ->
						lines.indices
							.filter { index -> markers.any { it.containsMatchIn(lines[index]) } }
							.mapNotNull { declaredAnnotation(lines, it) }
					}.filter(annotations::add)
			found.forEach { markers += Regex("""@(?:[\w.]+\.)?${Regex.escape(it)}\b(?!\.)""") }
		} while (found.isNotEmpty())
		return markers
	}

	/** Nazwa adnotacji, gdy oznaczenie w linii [index] stoi na jej deklaracji, a nie na teście. */
	private fun declaredAnnotation(
		lines: List<String>,
		index: Int,
	): String? =
		(index until minOf(lines.size, index + DECLARATION_LOOKAHEAD))
			.firstOrNull { DECLARATION.containsMatchIn(lines[it]) }
			?.let { ANNOTATION_DECLARATION.find(lines[it])?.groupValues?.get(1) }

	private fun entry(
		file: String,
		lines: List<String>,
		index: Int,
	): QuarantineEntry {
		val comment = (maxOf(0, index - 3) until index).reversed().firstNotNullOfOrNull { COMMENT.find(lines[it]) }
		return QuarantineEntry(file, index + 1, comment?.groupValues?.get(1), comment?.groupValues?.get(2)?.let(LocalDate::parse))
	}

	fun missing(entries: List<QuarantineEntry>): List<GateFinding> =
		entries.filter { it.issue == null }.map {
			GateFinding(
				PlatformGates.QUARANTINE_UNTRACKED,
				"${it.file}:${it.line} quarantines a test without \"// quarantine: <issue-url> until YYYY-MM-DD\" in the three lines above",
			)
		}

	fun expired(
		entries: List<QuarantineEntry>,
		today: LocalDate,
	): List<GateFinding> =
		entries.filter { it.until != null && it.until.isBefore(today) }.map {
			GateFinding(
				PlatformGates.QUARANTINE_EXPIRED,
				"${it.file}:${it.line} stayed in quarantine past ${it.until} (${it.issue}): fix the test and remove the tag, " +
					"or extend the date with a reason in the issue",
			)
		}
}
