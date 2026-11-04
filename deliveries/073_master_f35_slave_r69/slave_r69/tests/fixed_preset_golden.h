#pragma once
#include "math_golden.h"
// 原独立整数数学不改；仅显式给RUN相位端口固定预设，取消外部FLL输入。
struct FixedPresetGolden : independent_anc::LegacyGolden {
    bool wrong_phase_negative=false;
    int sample(int error) {
        fll.inc=selected_increment+(wrong_phase_negative&&mode==RUN?1048576u:0u);
        int result=independent_anc::LegacyGolden::sample(error);
        // LegacyGolden自带FLL的下一帧值不是本候选的外部输入；不消费它。
        fll.inc=selected_increment;
        return result;
    }
};
