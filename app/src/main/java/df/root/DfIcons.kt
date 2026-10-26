package df.root

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * The ten 24dp glyphs this UI needs.
 *
 * They live here instead of depending on `top.yukonga.miuix.kmp:miuix-icons`,
 * which ships a thousand-plus icon classes. In a debug APK that artifact alone
 * was ~13 MB of dex; drawing the handful of icons locally keeps the same look
 * without the weight. Icons are stroked/filled black and tinted by MIUIX's
 * [top.yukonga.miuix.kmp.basic.Icon], like the library icons were.
 */
object DfIcons {
    val Home: ImageVector by lazy {
        build("DfRoot.Home") {
            stroke {
                moveTo(3.5f, 10.5f)
                lineTo(12f, 3.5f)
                lineTo(20.5f, 10.5f)
                moveTo(5.5f, 9f)
                lineTo(5.5f, 20.5f)
                lineTo(18.5f, 20.5f)
                lineTo(18.5f, 9f)
                moveTo(9.5f, 20.5f)
                lineTo(9.5f, 14.5f)
                lineTo(14.5f, 14.5f)
                lineTo(14.5f, 20.5f)
            }
        }
    }

    val Records: ImageVector by lazy {
        build("DfRoot.Records") {
            stroke {
                moveTo(8.5f, 6.5f)
                lineTo(20.5f, 6.5f)
                moveTo(8.5f, 12f)
                lineTo(20.5f, 12f)
                moveTo(8.5f, 17.5f)
                lineTo(20.5f, 17.5f)
            }
            fill {
                circle(4.5f, 6.5f, 1.1f)
                circle(4.5f, 12f, 1.1f)
                circle(4.5f, 17.5f, 1.1f)
            }
        }
    }

    val Settings: ImageVector by lazy {
        build("DfRoot.Settings") {
            stroke {
                moveTo(3.5f, 6.5f)
                lineTo(20.5f, 6.5f)
                moveTo(3.5f, 12f)
                lineTo(20.5f, 12f)
                moveTo(3.5f, 17.5f)
                lineTo(20.5f, 17.5f)
            }
            fill {
                circle(8.5f, 6.5f, 2.1f)
                circle(15.5f, 12f, 2.1f)
                circle(9.5f, 17.5f, 2.1f)
            }
        }
    }

    val Import: ImageVector by lazy {
        build("DfRoot.Import") {
            stroke {
                moveTo(12f, 3.5f)
                lineTo(12f, 14.5f)
                moveTo(7.5f, 10f)
                lineTo(12f, 14.5f)
                lineTo(16.5f, 10f)
                moveTo(4.5f, 16.5f)
                lineTo(4.5f, 20.5f)
                lineTo(19.5f, 20.5f)
                lineTo(19.5f, 16.5f)
            }
        }
    }

    val Download: ImageVector by lazy {
        build("DfRoot.Download") {
            stroke {
                moveTo(12f, 3.5f)
                lineTo(12f, 15f)
                moveTo(7.5f, 10.5f)
                lineTo(12f, 15f)
                lineTo(16.5f, 10.5f)
                moveTo(5f, 20.5f)
                lineTo(19f, 20.5f)
            }
        }
    }

    val Layers: ImageVector by lazy {
        build("DfRoot.Layers") {
            stroke {
                moveTo(12f, 3f)
                lineTo(21f, 8f)
                lineTo(12f, 13f)
                lineTo(3f, 8f)
                close()
                moveTo(3f, 12f)
                lineTo(12f, 17f)
                lineTo(21f, 12f)
                moveTo(3f, 16f)
                lineTo(12f, 21f)
                lineTo(21f, 16f)
            }
        }
    }

    val Play: ImageVector by lazy {
        build("DfRoot.Play") {
            fill {
                moveTo(8f, 5f)
                lineTo(19f, 12f)
                lineTo(8f, 19f)
                close()
            }
        }
    }

    val Refresh: ImageVector by lazy {
        build("DfRoot.Refresh") {
            stroke {
                moveTo(19.5f, 8.5f)
                curveTo(18f, 5.8f, 15.2f, 4f, 12f, 4f)
                curveTo(7.6f, 4f, 4f, 7.6f, 4f, 12f)
                curveTo(4f, 16.4f, 7.6f, 20f, 12f, 20f)
                curveTo(15.2f, 20f, 18f, 18.2f, 19.5f, 15.5f)
                moveTo(15.5f, 8.5f)
                lineTo(19.5f, 8.5f)
                lineTo(19.5f, 4.5f)
            }
        }
    }

    val Block: ImageVector by lazy {
        build("DfRoot.Block") {
            stroke {
                moveTo(12f, 3.5f)
                curveTo(16.7f, 3.5f, 20.5f, 7.3f, 20.5f, 12f)
                curveTo(20.5f, 16.7f, 16.7f, 20.5f, 12f, 20.5f)
                curveTo(7.3f, 20.5f, 3.5f, 16.7f, 3.5f, 12f)
                curveTo(3.5f, 7.3f, 7.3f, 3.5f, 12f, 3.5f)
                close()
                moveTo(6.5f, 6.5f)
                lineTo(17.5f, 17.5f)
            }
        }
    }

    val ChevronRight: ImageVector by lazy {
        build("DfRoot.ChevronRight") {
            stroke {
                moveTo(9.5f, 6f)
                lineTo(15.5f, 12f)
                lineTo(9.5f, 18f)
            }
        }
    }

    val Check: ImageVector by lazy {
        build("DfRoot.Check") {
            stroke {
                moveTo(4.5f, 12.5f)
                lineTo(9.5f, 17.5f)
                lineTo(19.5f, 7.5f)
            }
        }
    }

    val Close: ImageVector by lazy {
        build("DfRoot.Close") {
            stroke {
                moveTo(6f, 6f)
                lineTo(18f, 18f)
                moveTo(18f, 6f)
                lineTo(6f, 18f)
            }
        }
    }
}

private fun build(name: String, block: ImageVector.Builder.() -> Unit): ImageVector =
    ImageVector.Builder(
        name = name,
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    ).apply(block).build()

private fun ImageVector.Builder.stroke(block: PathBuilder.() -> Unit) {
    path(
        fill = null,
        stroke = SolidColor(Color.Black),
        strokeLineWidth = 1.8f,
        strokeLineCap = StrokeCap.Round,
        strokeLineJoin = StrokeJoin.Round,
    ) { block() }
}

private fun ImageVector.Builder.fill(block: PathBuilder.() -> Unit) {
    path(fill = SolidColor(Color.Black)) { block() }
}

private fun PathBuilder.circle(cx: Float, cy: Float, radius: Float) {
    moveTo(cx, cy - radius)
    // Four 90-degree arcs; isMoreThanHalf must be false or each segment would
    // take the 270-degree route and turn the dot into a blob.
    arcTo(radius, radius, 0f, false, true, cx + radius, cy)
    arcTo(radius, radius, 0f, false, true, cx, cy + radius)
    arcTo(radius, radius, 0f, false, true, cx - radius, cy)
    arcTo(radius, radius, 0f, false, true, cx, cy - radius)
    close()
}
