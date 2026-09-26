package com.notel.notel.ui.component

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelTextSecondary

/**
 * Small, consistent medical disclaimer shown above AI-generated insights and
 * report-generation flows. Keep wording aligned with the clinical PDF
 * disclaimer (ReportGenerator) and ToS section 1.
 */
@Composable
fun MedicalDisclaimerBanner(modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = NotelPrimary.copy(alpha = 0.06f),
        modifier = modifier.fillMaxWidth()
    ) {
        Text(
            text = "Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition. AI insights are informational only. Consult a healthcare professional.",
            color = NotelTextSecondary,
            fontSize = 11.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)
        )
    }
}
