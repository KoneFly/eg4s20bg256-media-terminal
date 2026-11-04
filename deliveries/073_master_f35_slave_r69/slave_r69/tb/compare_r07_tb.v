module compare_r07_tb(input wire [47:0] a,b,output wire [3:0] old_flags,new_flags);
old_rise_r07 #(.WIDTH(8)) old8(.sample(a[7:0]),.baseline(b[7:0]),.increased(old_flags[0]));
anc_rise_compare_r62 #(.WIDTH(8)) new8(.sample(a[7:0]),.baseline(b[7:0]),.increased(new_flags[0]));
old_rise_r07 #(.WIDTH(16)) old16(.sample(a[15:0]),.baseline(b[15:0]),.increased(old_flags[1]));
anc_rise_compare_r62 #(.WIDTH(16)) new16(.sample(a[15:0]),.baseline(b[15:0]),.increased(new_flags[1]));
old_rise_r07 #(.WIDTH(32)) old32(.sample(a[31:0]),.baseline(b[31:0]),.increased(old_flags[2]));
anc_rise_compare_r62 #(.WIDTH(32)) new32(.sample(a[31:0]),.baseline(b[31:0]),.increased(new_flags[2]));
old_rise_r07 #(.WIDTH(48)) old48(.sample(a[47:0]),.baseline(b[47:0]),.increased(old_flags[3]));
anc_rise_compare_r62 #(.WIDTH(48)) new48(.sample(a[47:0]),.baseline(b[47:0]),.increased(new_flags[3]));
endmodule
