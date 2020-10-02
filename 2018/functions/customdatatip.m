function output_txt = customdatatip(obj,event_obj,str)
pos = get(event_obj, 'Position');
output_txt = {...
    ['X: ', num2str(pos(1),4)]...
    ['Y: ', num2str(pos(2),4)] ...
    ['legend: ', event_obj.Target.DisplayName]...
};